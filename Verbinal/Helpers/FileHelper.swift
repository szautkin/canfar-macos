// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Shared file system utilities used across modules.
enum FileHelper {

    /// FITS file extensions recognized across the app.
    static let fitsExtensions: Set<String> = ["fits", "fit", "fts", "fz"]

    /// Check if a file extension is a FITS format.
    static func isFITS(_ ext: String) -> Bool { fitsExtensions.contains(ext.lowercased()) }

    /// `~/Downloads/<stem>-<yyyyMMdd-HHmmss>.<ext>` for an export; the temp
    /// directory stands in when Downloads is unavailable.
    static func timestampedDownloadsURL(stem: String, ext: String, at date: Date = Date()) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return downloads.appendingPathComponent(
            "\(stem)-\(SharedFormatters.fileNameStamp.string(from: date)).\(ext)")
    }

    /// Move a file from source to destination, replacing if exists.
    static func moveReplacing(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
