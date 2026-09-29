// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// An observation kept in Research: its details, and its file on this
/// computer when it has one. A record may have no file — saved to read
/// about later, or its file removed to free space — and Download brings
/// the file back to the same record.
struct DownloadedObservation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var publisherID: String
    var collection: String
    var observationID: String
    var targetName: String
    var instrument: String
    var filter: String
    var ra: String
    var dec: String
    var startDate: String
    var calLevel: String
    /// The file, relative to Downloads or absolute; empty when Research
    /// keeps the observation without one (`isDownloaded`).
    var localPath: String
    var fileSize: Int64?
    var downloadedAt: Date = Date()
    var thumbnailURL: String?
    var previewURL: String?
    /// Security-scoped bookmark for `localPath`. Captured at save time from
    /// the user-picked `NSSavePanel` URL so the sandbox can re-grant read
    /// access on subsequent launches; without this, the path string alone
    /// resolves to a URL the sandbox refuses to open. `nil` for legacy rows
    /// downloaded before this field existed — those use the re-grant path.
    var bookmarkData: Data? = nil
    /// Provenance stamp when an MCP-connected agent staged the
    /// download via a proposal. `nil` when the user initiated the
    /// download themselves through the in-app UI. Drives the wand
    /// badge in research observation rows.
    var agentAttribution: AgentAttribution? = nil
    /// Set for a cutout — part of one of the observation's files — kept
    /// beside the complete observation, never as the whole of it.
    var cutout: CutoutSpec? = nil

    var isCutout: Bool { cutout != nil }

    /// What makes a record the one it is in Research: the observation,
    /// and which cutout of it (none for the complete observation).
    var recordKey: String { cutout.map { "\(publisherID)#\($0.key)" } ?? publisherID }

    /// Create from a SearchResult row using its column metadata.
    static func from(
        result: SearchResult,
        columns: SearchResultColumns,
        localPath: String,
        bookmarkData: Data? = nil,
        dataLink: DataLinkResult? = nil
    ) -> DownloadedObservation {
        DownloadedObservation(
            publisherID: columns.value(in: result, forID: "publisherid"),
            collection: columns.value(in: result, forID: "collection"),
            observationID: columns.value(in: result, forID: "obsid"),
            targetName: columns.value(in: result, forID: "targetname"),
            instrument: columns.value(in: result, forID: "instrument"),
            filter: columns.value(in: result, forID: "filter"),
            ra: columns.value(in: result, forID: "ra(j20000)"),
            dec: columns.value(in: result, forID: "dec(j20000)"),
            startDate: columns.value(in: result, forID: "startdate"),
            calLevel: columns.value(in: result, forID: "callev"),
            localPath: localPath,
            thumbnailURL: dataLink?.firstThumbnail?.absoluteString,
            previewURL: dataLink?.firstPreview?.absoluteString,
            bookmarkData: bookmarkData
        )
    }

    /// Research keeps a file for this observation (it may still be
    /// missing from disk — see `fileExists`).
    var isDownloaded: Bool { !localPath.isEmpty }

    /// Full local file URL; nil when there is no file. Prefers a
    /// sandbox-readable candidate (tilde expansion, container ↔
    /// user-facing Downloads) so FITS tools and the research archive agree
    /// on whether the file is there. Never the empty path, which is the
    /// working directory.
    var localURL: URL? {
        guard isDownloaded else { return nil }
        return resolvedReadableURL ?? URL(fileURLWithPath: expandedLocalPath)
    }

    /// The same observation without its file.
    func withoutFile() -> DownloadedObservation {
        var record = self
        record.localPath = ""
        record.fileSize = nil
        record.bookmarkData = nil
        return record
    }

    /// Whether the local file still exists on disk — including the
    /// sandbox-mapped Downloads twin of `localPath`. Do not treat a
    /// raw-string miss as "file gone"; the bookmark may still open it.
    /// The file is there — found through its bookmark or at its path.
    var fileExists: Bool {
        withReadableFile { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// What is wrong with the kept file — missing, unreadable, empty, an
    /// empty archive — or nil when it holds something; nil too for a record
    /// kept without a file.
    var fileProblem: DownloadedFileCheck.Problem? {
        guard isDownloaded else { return nil }
        return withReadableFile { DownloadedFileCheck.problem(at: $0) } ?? .missing
    }

    /// The file through its security-scoped bookmark — how Verbinal reaches
    /// a file outside its own folders, such as one saved to ~/Documents —
    /// and whether the bookmark wants renewing; nil without a bookmark, or
    /// when it no longer resolves.
    func bookmarkedFile() -> (url: URL, stale: Bool)? {
        #if os(macOS)
        guard let data = bookmarkData else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
        #else
        return nil
        #endif
    }

    /// Runs `body` on the record's file, opened as Verbinal may open it:
    /// through its bookmark first (with the access that grants), else at
    /// its path. Nil when there is no file to open. The one way every
    /// reader of a record's file gets at it.
    func withReadableFile<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard isDownloaded else { return nil }
        if let bookmarked = bookmarkedFile()?.url, bookmarked.startAccessingSecurityScopedResource() {
            defer { bookmarked.stopAccessingSecurityScopedResource() }
            return try body(bookmarked)
        }
        guard let url = resolvedReadableURL else { return nil }
        return try body(url)
    }

    /// First existing file URL for `localPath`, or `nil` if none of the
    /// sandbox/tilde candidates exist. Bookmark resolution is separate
    /// (FITS tools try the bookmark even when this is nil).
    var resolvedReadableURL: URL? {
        guard isDownloaded else { return nil }
        #if os(macOS)
        return LocalFolderAccessStore.readableURL(for: localPath, directory: false)
        #else
        var isDir: ObjCBool = false
        let path = expandedLocalPath
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path)
        #endif
    }

    private var expandedLocalPath: String {
        #if os(macOS)
        return LocalFolderAccessStore.expandedPath(localPath)
        #else
        return (localPath as NSString).expandingTildeInPath
        #endif
    }

    /// Display filename extracted from the local path; empty without a file.
    var filename: String {
        localURL?.lastPathComponent ?? ""
    }
}
