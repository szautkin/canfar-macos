// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// The person's storage, as Research's files go to and from it.
protocol ResearchStorage: Sendable {
    /// Puts `file` in `folder`; answers its path from the home. A file of
    /// that name already there is never written over: when it is the same
    /// size it is taken for this one, else the send is refused.
    func send(_ file: URL, toFolder folder: String) async throws -> String
    /// Fetches the file at `path` into a temporary file.
    func fetch(_ path: String) async throws -> URL
    /// Removes the file at `path`.
    func remove(_ path: String) async throws
}

/// A Research file between this Mac and the person's CANFAR storage (the
/// person's request, 2026-10-09): sent there, brought back, or moved —
/// and a copy removed only while the other is there, so a file always
/// keeps one. Each is the person's action, or an assistant's they allow.
@Observable
@MainActor
final class ResearchFileTransfer {
    /// Where Research's files go in storage: where Results sends them too.
    nonisolated static let folder = "\(ResultDestination.folder)/research"

    enum Failure: LocalizedError, Equatable {
        case noRecord
        case noFile(String)
        case signedOut
        /// The copy that would be the last one.
        case onlyCopy(String)
        case notOnMac(String)
        case notInStorage(String)

        var errorDescription: String? {
            switch self {
            case .noRecord: String(localized: "That record is not in Research.")
            case .noFile(let name): String(localized: "The record has no file \(name).")
            case .signedOut: String(localized: "Sign in to CANFAR to reach your storage.")
            case .onlyCopy(let name): String(localized: "\(name) has no other copy: removing this one would lose it.")
            case .notOnMac(let name): String(localized: "\(name) is not on this Mac.")
            case .notInStorage(let name): String(localized: "\(name) is not in your storage.")
            }
        }
    }

    /// Where a move puts a file.
    enum Destination: String, Sendable { case mac, storage }

    private let store: ObservationStore
    private let files: ResearchFiles
    private let downloads: DownloadService
    private let changes: ChangeLog
    /// The person's storage while they are signed in to CANFAR.
    var storage: (any ResearchStorage)?
    @ObservationIgnored var tasks: TaskRegistry = .shared
    /// Files on their way, by record and name: the screen shows them busy.
    private(set) var busy: Set<String> = []

    init(store: ObservationStore, files: ResearchFiles, downloads: DownloadService, changes: ChangeLog = .shared) {
        self.store = store
        self.files = files
        self.downloads = downloads
        self.changes = changes
    }

    static func key(_ recordID: UUID, _ name: String) -> String { "\(recordID.uuidString)\n\(name)" }

    func isBusy(_ name: String, of recordID: UUID) -> Bool { busy.contains(Self.key(recordID, name)) }

    // MARK: - Copies

    /// Sends the file `name` of the record to the person's storage; it stays on this Mac.
    @discardableResult
    func send(_ name: String, of recordID: UUID) async throws -> DownloadedObservation {
        let (record, file) = try find(name, recordID)
        guard file.places.onMac, let url = file.local.bookmarked()?.url ?? file.local.readableURL else { throw Failure.notOnMac(name) }
        if file.places.inStorage { return record }
        guard let storage else { throw Failure.signedOut }
        let path = try await working(name, recordID, String(localized: "Send \(name) to your storage"),
                                     again: { [weak self] in Task { try? await self?.send(name, of: recordID) } }) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try await storage.send(url, toFolder: Self.folder)
        }
        let updated = setStoragePath(path, of: file, in: try current(recordID))
        changes.done("send_research_file_to_storage", "\(name) of \(ObservationStore.describe(updated)) to your storage at \(path)")
        return updated
    }

    /// Brings the file `name` of the record from the person's storage to
    /// this Mac's download folder; it stays in storage.
    @discardableResult
    func fetch(_ name: String, of recordID: UUID) async throws -> DownloadedObservation {
        let (record, file) = try find(name, recordID)
        if file.places.onMac, file.local.exists { return record }
        guard let path = file.storagePath else { throw Failure.notInStorage(name) }
        guard let storage else { throw Failure.signedOut }
        let placed = try await working(name, recordID, String(localized: "Get \(name) from your storage"),
                                       again: { [weak self] in Task { try? await self?.fetch(name, of: recordID) } }) {
            let temp = try await storage.fetch(path)
            // From storage, so not sent back to it as a new result.
            return try await DownloadPlacement.place(temp, named: name, downloads: self.downloads, asResult: false)
        }
        var updated = try current(recordID)
        if file.isMain {
            updated.localPath = placed.localPath
            updated.bookmarkData = placed.bookmark
            updated.fileSize = placed.size ?? updated.fileSize
        } else if var list = updated.files, let index = list.firstIndex(where: { $0.name == file.name }) {
            list[index].localPath = placed.localPath
            list[index].bookmarkData = placed.bookmark
            list[index].size = placed.size ?? list[index].size
            updated.files = list
        }
        let stored = store.save(updated)
        changes.done("get_research_file_from_storage", "\(name) of \(ObservationStore.describe(stored)) from your storage")
        return stored
    }

    /// Removes the file's copy on this Mac; it stays in the person's storage.
    @discardableResult
    func removeFromMac(_ name: String, of recordID: UUID) async throws -> DownloadedObservation {
        let (record, file) = try find(name, recordID)
        guard file.places.onMac else { return record }
        guard file.places.inStorage else { throw Failure.onlyCopy(name) }
        guard let kept = try await files.remove(fileNamed: file.name, of: recordID) else { throw Failure.noFile(name) }
        return kept
    }

    /// Removes the file's copy in the person's storage; it stays on this Mac.
    @discardableResult
    func removeFromStorage(_ name: String, of recordID: UUID) async throws -> DownloadedObservation {
        let (record, file) = try find(name, recordID)
        guard let path = file.storagePath else { return record }
        guard file.places.onMac, file.local.exists else { throw Failure.onlyCopy(name) }
        guard let storage else { throw Failure.signedOut }
        try await working(name, recordID, String(localized: "Remove \(name) from your storage"),
                          again: { [weak self] in Task { try? await self?.removeFromStorage(name, of: recordID) } }) {
            try await storage.remove(path)
        }
        let updated = setStoragePath(nil, of: file, in: try current(recordID))
        changes.done("remove_research_file_from_storage", "\(name) of \(ObservationStore.describe(updated)) from your storage at \(path)")
        return updated
    }

    /// Moves the file to `destination`: copied there first, and the other
    /// copy removed only once it is.
    @discardableResult
    func move(_ name: String, of recordID: UUID, to destination: Destination) async throws -> DownloadedObservation {
        switch destination {
        case .storage:
            try await send(name, of: recordID)
            return try await removeFromMac(name, of: recordID)
        case .mac:
            let (_, file) = try find(name, recordID)
            let fetched = try await fetch(name, of: recordID)
            // Its name on this Mac, which a clash in the download folder changes.
            let here = file.isMain ? fetched.mainKeptFile?.name ?? name : name
            return try await removeFromStorage(here, of: recordID)
        }
    }

    // MARK: - Helpers

    private func find(_ name: String, _ recordID: UUID) throws -> (DownloadedObservation, KeptFile) {
        let record = try current(recordID)
        guard let file = record.anyFile(named: name) else { throw Failure.noFile(name) }
        return (record, file)
    }

    private func current(_ recordID: UUID) throws -> DownloadedObservation {
        guard let record = store.observation(id: recordID) else { throw Failure.noRecord }
        return record
    }

    private func setStoragePath(_ path: String?, of file: KeptFile, in record: DownloadedObservation) -> DownloadedObservation {
        var updated = record
        if file.isMain {
            updated.storagePath = path
        } else if var list = updated.files, let index = list.firstIndex(where: { $0.name == file.name }) {
            list[index].storagePath = path
            if path == nil, list[index].localPath.isEmpty { list.remove(at: index) }
            updated.files = list.isEmpty ? nil : list
        }
        return store.save(updated)
    }

    /// Runs `work` as the file's, on the activity bar.
    /// Runs a transfer as a task on the bar; should it fail, the bar's Retry
    /// does `again` (plan 44 E4), the person's to press.
    private func working<T>(_ name: String, _ recordID: UUID, _ label: String,
                            again: @escaping @MainActor () -> Void,
                            _ work: () async throws -> T) async throws -> T {
        let key = Self.key(recordID, name)
        busy.insert(key)
        defer { busy.remove(key) }
        let task = tasks.begin(.storage, label)
        do {
            let value = try await work()
            task.succeed()
            return value
        } catch {
            task.offerRetry { _ in again() }
            task.fail(error.localizedDescription)
            throw error
        }
    }
}
