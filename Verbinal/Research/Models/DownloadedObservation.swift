// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

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

    /// Create from a SearchResult row.
    static func from(result: SearchResult, localPath: String, dataLink: DataLinkResult? = nil) -> DownloadedObservation {
        DownloadedObservation(
            publisherID: result.publisherID,
            collection: result.collection,
            observationID: result.observationID,
            targetName: result.targetName,
            instrument: result.instrument,
            filter: result.filter,
            ra: result.ra,
            dec: result.dec,
            startDate: result.startDate,
            calLevel: result.calLevel,
            localPath: localPath,
            thumbnailURL: dataLink?.firstThumbnail?.absoluteString,
            previewURL: dataLink?.firstPreview?.absoluteString
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
