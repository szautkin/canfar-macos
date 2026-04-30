// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Metadata for a downloaded observation file stored locally.
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
    var localPath: String          // relative to downloads directory
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

    /// Build the expected local file path from observation metadata.
    static func buildLocalPath(collection: String, observationID: String, publisherID: String) -> String {
        // Extract productID from publisherID: ivo://cadc.nrc.ca/COLLECTION?OBSID/PRODUCTID
        let productID: String
        if let lastSlash = publisherID.lastIndex(of: "/") {
            productID = String(publisherID[publisherID.index(after: lastSlash)...])
        } else {
            productID = observationID
        }

        let safeCollection = collection.replacingOccurrences(of: "/", with: "_")
        let safeProduct = productID.replacingOccurrences(of: "/", with: "_")
        return "\(safeCollection)/\(safeProduct)"
    }

    /// Full local file URL.
    var localURL: URL {
        URL(fileURLWithPath: localPath)
    }

    /// Whether the local file still exists on disk.
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: localPath)
    }

    /// Display filename extracted from the local path.
    var filename: String {
        localURL.lastPathComponent
    }
}
