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

    /// Notebook file extensions.
    static let notebookExtensions: Set<String> = ["ipynb", "py", "md"]

    /// Check if a file extension is a FITS format.
    static func isFITS(_ ext: String) -> Bool { fitsExtensions.contains(ext.lowercased()) }

    /// Check if a file extension is a notebook format.
    static func isNotebook(_ ext: String) -> Bool { notebookExtensions.contains(ext.lowercased()) }

    /// Move a file from source to destination, replacing if exists.
    static func moveReplacing(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    // MARK: - Date Formatting

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy HH:mm"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    /// Format date as "MMM d, yyyy HH:mm".
    static func formatDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    /// Format date as "MMM d, HH:mm" (no year).
    static func formatShortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }
}
