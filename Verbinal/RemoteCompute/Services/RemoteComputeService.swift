// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// The sessions remote compute needs from the platform.
protocol ComputeSessions: Sendable {
    func getSessions() async throws -> [Session]
    func launchSession(_ params: SessionLaunchParams) async throws -> String?
    func deleteSession(id: String) async throws
}

/// The files remote compute needs in the person's home on /arc.
protocol ComputeFiles: Sendable {
    func uploadFile(username: String, remotePath: String, fileURL: URL) async throws
    func createFolder(username: String, parentPath: String, folderName: String) async throws
    /// The file's first `maxBytes`, or nil when it is not there (404).
    func readFile(username: String, path: String, maxBytes: Int) async throws -> Data?
}

extension SessionService: ComputeSessions {}

extension VOSpaceBrowserService: ComputeFiles {
    func readFile(username: String, path: String, maxBytes: Int) async throws -> Data? {
        do {
            return try await fetchBytes(username: username, path: path, offset: 0, maxBytes: maxBytes).data
        } catch NetworkError.httpError(404, _) {
            return nil
        }
    }
}

enum RemoteComputeError: LocalizedError, Equatable {
    case signedOut
    case notSetUp

    var errorDescription: String? {
        switch self {
        case .signedOut: return String(localized: "Sign in to CANFAR to use remote compute.")
        case .notSetUp: return String(localized: "No compute image is set — choose one in Settings ▸ Compute.")
        }
    }
}

/// Code run on a warm `contributed` session through the /arc file drop
/// (`RunCodeContract`): reuse — or launch, without waiting for Running —
/// the one session named `verbinal-compute`, put the request in its inbox,
/// and read the result from its out folder. The Remote Compute screen and
/// the assistant's tools do all of it through here, so they agree.
///
/// Every run is remembered with who sent it (`runs`) and watched until
/// its result arrives or it cannot still be going, so the history settles
/// whether or not anybody asks for the output.
@MainActor
final class RemoteComputeService {
    /// What a session is launched from and at.
    struct Configuration: Equatable, Sendable {
        var image: String
        var cores: Int
        var ram: Int

        var isConfigured: Bool { !image.isEmpty }
    }

    let runs: ComputeRunStore
    private let sessions: any ComputeSessions
    private let files: any ComputeFiles
    private let username: @MainActor () -> String
    private let configuration: @MainActor () -> Configuration
    private let registryAuth: @MainActor () -> (username: String, secret: String)?
    private let pollInterval: Duration
    /// How long past a run's own timeout to wait before calling it lost: a
    /// cold session takes a minute or two, and only then picks the request up.
    private let startupAllowance: TimeInterval
    private var watchers: [String: Task<Void, Never>] = [:]

    init(runs: ComputeRunStore,
         sessions: any ComputeSessions,
         files: any ComputeFiles,
         username: @escaping @MainActor () -> String,
         configuration: @escaping @MainActor () -> Configuration,
         registryAuth: @escaping @MainActor () -> (username: String, secret: String)?,
         pollInterval: Duration = .seconds(5),
         startupAllowance: TimeInterval = 5 * 60) {
        self.runs = runs
        self.sessions = sessions
        self.files = files
        self.username = username
        self.configuration = configuration
        self.registryAuth = registryAuth
        self.pollInterval = pollInterval
        self.startupAllowance = startupAllowance
    }

    var isSignedIn: Bool { !username().isEmpty }
    var current: Configuration { configuration() }

    // MARK: - Where it stands

    /// The compute session whatever its state — a failed or terminating one
    /// too, since the screen must say so; a live one wins over a dead one.
    func currentSession() async throws -> Session? {
        let ours = try await sessions.getSessions().filter(Self.isComputeSession)
        return ours.first { RunCodeContract.isLive($0.status) } ?? ours.first
    }

    /// The one answer the screen and `get_compute_state` both give. The
    /// session is looked for whether or not an image is set here.
    func snapshot() async throws -> ComputeSnapshot {
        let config = configuration()
        let session = isSignedIn ? try await currentSession() : nil
        return ComputeSnapshot(state: ComputeState(configured: config.isConfigured, sessionStatus: session?.status),
                               session: session, configuration: config)
    }

    // MARK: - The session

    /// Reuses the running or starting session, or launches one from
    /// `launch` (the Settings when nil) without waiting for it. Returns
    /// whether one was already there.
    @discardableResult
    func ensureSession(_ launch: Configuration? = nil) async throws -> Bool {
        let config = launch ?? configuration()
        guard config.isConfigured else { throw RemoteComputeError.notSetUp }
        let user = try signedInUser()
        if try await warmSession() != nil { return true }
        let credentials = registryAuth()
        _ = try await sessions.launchSession(SessionLaunchParams(
            type: RunCodeContract.sessionType, name: RunCodeContract.sessionName, image: config.image,
            cores: RunCodeContract.clampCores(config.cores), ram: RunCodeContract.clampRam(config.ram), gpus: 0,
            cmd: nil, registryUsername: credentials?.username, registrySecret: credentials?.secret))
        await ensureTree(user)
        return false
    }

    /// Deletes the running or starting session; false when there is none.
    @discardableResult
    func stop() async throws -> Bool {
        guard let session = try await warmSession() else { return false }
        try await sessions.deleteSession(id: session.id)
        return true
    }

    // MARK: - Runs

    /// Sends `request` as `author`'s, starting the session if need be, and
    /// returns without waiting for the result.
    func submit(_ request: RunCodeContract.Request, by author: ComputeRun.Author, launch: Configuration? = nil) async throws {
        let user = try signedInUser()
        let request = RunCodeContract.Request(id: request.id, language: request.language,
                                              code: RunCodeContract.normalizeNewlines(request.code),
                                              timeout_seconds: request.timeout_seconds)
        runs.add(ComputeRun(request, author: author))
        do {
            try await ensureSession(launch)
            // A just-launched session may not have made its inbox yet, and a missing parent 404s the PUT.
            await ensureTree(user)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("runcode-\(RunCodeContract.sanitize(request.id)).json")
            try JSONEncoder().encode(request).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            try await files.uploadFile(username: user, remotePath: RunCodeContract.inboxPath(id: request.id), fileURL: file)
        } catch {
            runs.close(request.id, as: ComputeRun.notSent)
            throw error
        }
        watch(request)
    }

    /// Reads a run's result; whoever reads it first records it.
    func fetchOut(_ id: String) async throws -> RunCodeContract.Fetched {
        let user = try signedInUser()
        let fetched = RunCodeContract.Fetched(
            try await files.readFile(username: user, path: RunCodeContract.outPath(id: id), maxBytes: RunCodeContract.maxResultBytes))
        if case .done(let result) = fetched { runs.complete(id, with: result) }
        return fetched
    }

    /// Stops watching every run — on sign-out.
    func stopWatching() {
        watchers.values.forEach { $0.cancel() }
        watchers = [:]
    }

    private func watch(_ request: RunCodeContract.Request) {
        let id = request.id
        let giveUpAt = Date().addingTimeInterval(TimeInterval(request.timeout_seconds) + startupAllowance)
        let interval = pollInterval
        watchers[id]?.cancel()
        watchers[id] = Task { [weak self] in
            while Date() < giveUpAt, !Task.isCancelled {
                guard let self else { return }
                if await self.settled(id) { break }
                try? await Task.sleep(for: interval)
            }
            guard let self, !Task.isCancelled else { return }
            self.runs.close(id, as: ComputeRun.noResult)
            self.watchers[id] = nil
        }
    }

    /// Whether the run is finished — read by someone else already, or now.
    private func settled(_ id: String) async -> Bool {
        if runs.find(id)?.isFinished == true { return true }
        if case .done = try? await fetchOut(id) { return true }
        return false
    }

    // MARK: - Plumbing

    /// Matched by name and type, not image, so it survives the registry
    /// prefix a launch adds — and so the Portal can tell it is the assistant's.
    static func isComputeSession(_ session: Session) -> Bool {
        session.sessionType.lowercased() == RunCodeContract.sessionType && session.sessionName == RunCodeContract.sessionName
    }

    private func warmSession() async throws -> Session? {
        try await sessions.getSessions().first { Self.isComputeSession($0) && RunCodeContract.isLive($0.status) }
    }

    private func signedInUser() throws -> String {
        let user = username()
        guard !user.isEmpty else { throw RemoteComputeError.signedOut }
        return user
    }

    /// The coordination tree, a level at a time; one already there is fine.
    private func ensureTree(_ user: String) async {
        try? await files.createFolder(username: user, parentPath: "", folderName: ".verbinal")
        try? await files.createFolder(username: user, parentPath: ".verbinal", folderName: "exec")
        try? await files.createFolder(username: user, parentPath: RunCodeContract.execDir, folderName: "inbox")
        try? await files.createFolder(username: user, parentPath: RunCodeContract.execDir, folderName: "out")
    }
}
