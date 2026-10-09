// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// A downloaded temporary file put in the download folder, ready to be
/// kept in Research: its path, its size, and a security-scoped bookmark so
/// a later launch can open it again (plan 34 F). The temporary file is
/// removed when the move fails. Every download Verbinal keeps lands here.
enum DownloadPlacement {
    struct Placed: Sendable {
        let localPath: String
        let size: Int64?
        let bookmark: Data?
    }

    static func place(_ tempURL: URL, named name: String, downloads: DownloadService) async throws -> Placed {
        let finalURL: URL
        do {
            finalURL = try DownloadsFolder.move(tempURL, named: name)
        } catch {
            try? await downloads.deleteFile(at: tempURL)
            throw ProposalApplyError.backendError("moving \(name) into \(DownloadsFolder.url.lastPathComponent) failed: \(error.localizedDescription)")
        }
        #if os(macOS)
        let bookmark = try? finalURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let path = LocalFolderAccessStore.userFacingPath(for: finalURL)
        #else
        let bookmark: Data? = nil
        let path = finalURL.path
        #endif
        return Placed(localPath: path, size: await downloads.fileSize(at: finalURL), bookmark: bookmark)
    }
}

/// An observation's files in Research (plan 34 F): the one way one is
/// downloaded — from the Files tab, Research's detail, or an assistant —
/// and the one way it is removed. It knows the store and the download
/// service; the views ask it what state each file is in.
@Observable
@MainActor
final class ResearchFiles {
    /// Where a file comes from.
    enum Source: Sendable, Equatable {
        /// Its archive URI, as the Files tab lists it.
        case artifact(uri: String)
        /// Its name among the plane's files, as `get_data_links` gives it.
        case named(String)

        var name: String {
            switch self {
            case .artifact(let uri): (uri as NSString).lastPathComponent
            case .named(let name): name
            }
        }
    }

    /// What a file of an observation is to Research.
    enum State: Equatable {
        case notKept
        case downloading
        case kept(KeptFile)
    }

    private let store: ObservationStore
    private let downloads: DownloadService
    /// Downloads under way, by record and file.
    private(set) var downloading: Set<String> = []
    /// Told when a download made a new record: the app completes it from
    /// the archive.
    var onNewRecord: ((DownloadedObservation) -> Void)?

    init(store: ObservationStore, downloads: DownloadService) {
        self.store = store
        self.downloads = downloads
    }

    private static func key(_ publisherID: String, _ name: String) -> String { "\(publisherID)\n\(name)" }

    /// The state of the observation's file `name`.
    func state(of name: String, publisherID: String) -> State {
        if downloading.contains(Self.key(publisherID, name)) { return .downloading }
        guard let file = store.whole(publisherID: publisherID)?.keptFile(named: name) else { return .notKept }
        return .kept(file)
    }

    /// Downloads the file into the download folder and keeps it with the
    /// observation `details` describes — Research's record of it, or a new
    /// one. Never over another file. Returns the record and the file.
    @discardableResult
    func download(_ source: Source, for details: DownloadedObservation,
                  attribution: AgentAttribution? = nil) async throws -> (record: DownloadedObservation, file: KeptFile) {
        let name = source.name
        let key = Self.key(details.publisherID, name)
        downloading.insert(key)
        defer { downloading.remove(key) }

        let fetched: (tempURL: URL, suggestedFilename: String)
        switch source {
        case .artifact(let uri): fetched = try await downloads.downloadToTemp(artifactURI: uri, publisherID: details.publisherID)
        case .named(let file): fetched = try await downloads.downloadToTemp(publisherID: details.publisherID, file: file)
        }
        let placed = try await DownloadPlacement.place(fetched.tempURL, named: name, downloads: downloads)
        var uri: String?
        if case .artifact(let artifactURI) = source { uri = artifactURI }
        let file = KeptFile(name: name, uri: uri, localPath: placed.localPath, bookmarkData: placed.bookmark,
                            size: placed.size, downloadedAt: Date(), agentAttribution: attribution)

        let existing = store.whole(publisherID: details.publisherID)
        let base = existing ?? details.withoutFile()
        let stored = store.save(base.keeping(file))
        if existing == nil { onNewRecord?(stored) }
        return (stored, file)
    }

    /// Deletes the record's file `name` from this computer — the main one
    /// when that is its name — and forgets it; the observation and its
    /// notes stay. Nil when Research has no such record or file.
    @discardableResult
    func remove(fileNamed name: String, of id: UUID) async throws -> DownloadedObservation? {
        guard let record = store.observation(id: id), let file = record.keptFile(named: name) else { return nil }
        if let url = file.local.readableURL ?? file.local.bookmarked()?.url {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if FileManager.default.fileExists(atPath: url.path) { try await downloads.deleteFile(at: url) }
        }
        return store.forgetFile(named: name, of: id)
    }
}
