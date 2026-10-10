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
    /// Where the main file is in the person's storage too, from their home,
    /// once sent there as a result (plan 36 4.1, 5.1).
    var storagePath: String? = nil
    /// Set for a cutout — part of one of the observation's files — kept
    /// beside the complete observation, never as the whole of it.
    var cutout: CutoutSpec? = nil
    /// The observation's other files on this computer (plan 34 F); nil for
    /// none, so records kept before read as they were written.
    var files: [KeptFile]? = nil

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

    /// The observation's main file, as Research reaches it.
    var mainFile: LocalFile { LocalFile(path: localPath, bookmarkData: bookmarkData) }

    /// Full local file URL; nil when there is no file. Prefers a
    /// sandbox-readable candidate (tilde expansion, container ↔
    /// user-facing Downloads) so FITS tools and the research archive agree
    /// on whether the file is there.
    var localURL: URL? { mainFile.url }

    /// The same observation without its main file; its other files stay.
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
    var fileExists: Bool { mainFile.exists }

    /// What is wrong with the kept file — missing, unreadable, empty, an
    /// empty archive — or nil when it holds something; nil too for a record
    /// kept without a file.
    var fileProblem: DownloadedFileCheck.Problem? { mainFile.problem }

    /// The file through its security-scoped bookmark — how Verbinal reaches
    /// a file outside its own folders, such as one saved to ~/Documents —
    /// and whether the bookmark wants renewing; nil without a bookmark, or
    /// when it no longer resolves.
    func bookmarkedFile() -> (url: URL, stale: Bool)? { mainFile.bookmarked() }

    /// Runs `body` on the record's file, opened as Verbinal may open it:
    /// through its bookmark first (with the access that grants), else at
    /// its path. Nil when there is no file to open. The one way every
    /// reader of a record's file gets at it.
    func withReadableFile<T>(_ body: (URL) throws -> T) rethrows -> T? {
        try mainFile.withReadable(body)
    }

    /// First existing file URL for `localPath`, or `nil` if none of the
    /// sandbox/tilde candidates exist. Bookmark resolution is separate
    /// (FITS tools try the bookmark even when this is nil).
    var resolvedReadableURL: URL? { mainFile.readableURL }

    // MARK: - Its other files (plan 34 F)

    /// The files downloaded one by one — from the Files tab, or an
    /// assistant's `download_observation` with `file` — beside the main one.
    var keptFiles: [KeptFile] { files ?? [] }

    /// Every file Research keeps for it: the main one, then the others.
    var localFiles: [LocalFile] { (isDownloaded ? [mainFile] : []) + keptFiles.map(\.local) }

    /// The kept file of that name, the main one included.
    func keptFile(named name: String) -> KeptFile? {
        if let file = keptFiles.first(where: { $0.name == name }) { return file }
        guard isDownloaded, (localPath as NSString).lastPathComponent == name else { return nil }
        return KeptFile(name: name, localPath: localPath, bookmarkData: bookmarkData, size: fileSize,
                        downloadedAt: downloadedAt, agentAttribution: agentAttribution, isMain: true)
    }

    /// The same observation with `file`, in place of one of the same name.
    func keeping(_ file: KeptFile) -> DownloadedObservation {
        var record = self
        var list = keptFiles.filter { $0.name != file.name }
        list.append(file)
        record.files = list
        return record
    }

    /// The same observation without its file `name`: the main one when that
    /// is its name.
    func forgetting(fileNamed name: String) -> DownloadedObservation {
        if keptFiles.contains(where: { $0.name == name }) {
            var record = self
            let list = keptFiles.filter { $0.name != name }
            record.files = list.isEmpty ? nil : list
            return record
        }
        return keptFile(named: name)?.isMain == true ? withoutFile() : self
    }

    /// Display filename extracted from the local path; empty without a file.
    var filename: String {
        localURL?.lastPathComponent ?? ""
    }
}
