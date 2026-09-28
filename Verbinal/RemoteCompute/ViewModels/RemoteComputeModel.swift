// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// The Remote Compute screen: the session, every run with its code and
/// output, and a box to run code as yourself. What the rules are — which
/// state a status means, what may be done in each — is `ComputeState`'s;
/// the history is `ComputeRunStore`'s. This only holds what is on screen,
/// for the view and for the agent's screen tools alike.
@Observable
@MainActor
final class RemoteComputeModel {
    enum Tab: String, Sendable {
        /// The selected run's code and output.
        case run
        /// The Run code box.
        case code
    }

    /// The selected run's output, as far as it can be read.
    enum Output: Equatable {
        case none
        case waiting
        case loading
        case text(stdout: String, stderr: String, truncated: Bool)
        case unavailable(String)
    }

    struct Message: Equatable {
        enum Kind { case info, warning, error }
        let kind: Kind
        let text: String
    }

    let service: RemoteComputeService

    private(set) var snapshot: ComputeSnapshot?
    var tab: Tab = .run
    var selectedRunID: String?
    private(set) var output: Output = .none
    /// The status the output was read at, so a run that finishes is read again.
    private var outputReadAt: String?
    var language = RunCodeContract.supportedLanguages[0]
    var timeoutSeconds = RunCodeContract.defaultTimeoutSeconds
    var code = ""
    private(set) var isBusy = false
    var message: Message?

    init(service: RemoteComputeService) {
        self.service = service
    }

    var state: ComputeState { snapshot?.state ?? (service.current.isConfigured ? .stopped : .notSetUp) }
    var isConfigured: Bool { service.current.isConfigured }
    var hasSession: Bool { snapshot?.session != nil }
    var runs: [ComputeRun] { service.runs.runs }
    var selectedRun: ComputeRun? { selectedRunID.flatMap(service.runs.find) }

    var canStart: Bool { !isBusy && state.canStart(configured: isConfigured) }
    var canStop: Bool { !isBusy && state.canStop }
    var canRun: Bool { !isBusy && state.canRun(configured: isConfigured) }
    /// Whether something is changing that a quiet re-read would show.
    var isChanging: Bool { state == .starting || state == .stopping || runs.contains { !$0.isFinished } }

    // MARK: - Where it stands

    /// Reads the session again, saying so when it cannot — unless `quiet`.
    func refresh(quiet: Bool = false) async {
        if !quiet { isBusy = true }
        defer { if !quiet { isBusy = false } }
        do {
            snapshot = try await service.snapshot()
            if !isConfigured, hasSession, message == nil {
                message = Message(kind: .info, text: String(localized: "A compute session from another install is on your account, holding your cores. Stop it here, or set an image in Settings ▸ AI Compute to use it."))
            }
        } catch {
            if !quiet { message = Message(kind: .error, text: error.localizedDescription) }
        }
    }

    /// A tick of the screen's timer: re-read only while something is changing.
    func tick() async {
        if isChanging { await refresh(quiet: true) }
    }

    // MARK: - The session

    func start() async {
        await perform {
            try await self.service.ensureSession()
            self.message = Message(kind: .info, text: String(localized: "Starting — a compute session takes a minute or two to come up."))
        }
    }

    func stop() async {
        await perform { _ = try await self.service.stop() }
    }

    /// Stops the session and starts one with the settings — for a session
    /// that differs from them (``ComputeDrift``).
    func restartWithSettings() async {
        await perform {
            _ = try await self.service.stop()
            try await self.service.ensureSession()
            self.message = Message(kind: .info, text: String(localized: "Starting with the new settings — a compute session takes a minute or two to come up."))
        }
    }

    // MARK: - Runs

    /// Sends the Run code box as the person's.
    func runSnippet() async {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await submit(language: language, code: code, timeout: timeoutSeconds)
    }

    func runAgain() async {
        guard let run = selectedRun else { return }
        await submit(language: run.language, code: run.code, timeout: run.timeoutSeconds)
    }

    private func submit(language: String, code: String, timeout: Int) async {
        let id = UUID().uuidString
        let request = RunCodeContract.Request(id: id, language: language, code: code,
                                              timeout_seconds: RunCodeContract.clampTimeout(timeout))
        await perform {
            defer { self.select(id) }
            try await self.service.submit(request, by: .user)
        }
    }

    /// Shows a run's code at once, and its output as soon as it can be read.
    func select(_ id: String?) {
        selectedRunID = id
        tab = .run
        output = .none
        outputReadAt = nil
    }

    /// Reads the selected run's output — again when its status has moved on.
    func loadOutput() async {
        guard let run = selectedRun else { output = .none; return }
        guard outputReadAt != run.state || output == .none else { return }
        outputReadAt = run.state
        switch run.state {
        case ComputeRun.running:
            output = .waiting
            return
        case ComputeRun.noResult:
            output = .unavailable(String(localized: "Nothing came back in the time it could take. The session may have stopped before it ran; the code is still in the inbox and runs when it starts again."))
            return
        case ComputeRun.notSent:
            output = .unavailable(String(localized: "It never reached the session — see the message above."))
            return
        default:
            break
        }
        output = .loading
        do {
            let fetched = try await service.fetchOut(run.id)
            guard selectedRunID == run.id else { return }
            if case .done(let result) = fetched {
                output = .text(stdout: result.decodedStdout ?? "", stderr: result.decodedStderr ?? "", truncated: result.truncated == true)
            } else {
                output = .unavailable(String(localized: "The result is no longer in your storage."))
            }
        } catch {
            if selectedRunID == run.id { output = .unavailable(error.localizedDescription) }
        }
    }

    /// Puts code in the Run code box for the person to run — never runs it.
    func setSnippet(code: String, language: String, timeoutSeconds: Int) {
        self.code = code
        self.language = RunCodeContract.supportedLanguages.contains(language) ? language : RunCodeContract.supportedLanguages[0]
        self.timeoutSeconds = RunCodeContract.clampTimeout(timeoutSeconds)
        tab = .code
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            message = Message(kind: .error, text: error.localizedDescription)
        }
        await refresh(quiet: true)
    }
}
