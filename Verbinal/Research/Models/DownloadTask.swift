// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// State of an active download.
enum DownloadState: Equatable {
    case downloading
    case completed
    case failed(String)
    case cancelled
}

/// Tracks progress of a single file download.
struct DownloadProgress: Identifiable {
    let id: UUID
    let observation: DownloadedObservation
    var bytesReceived: Int64 = 0
    var totalBytes: Int64?
    var state: DownloadState = .downloading

    var fractionCompleted: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return Double(bytesReceived) / Double(total)
    }

    var formattedProgress: String {
        let received = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file)
        if let total = totalBytes {
            let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(received) / \(totalStr)"
        }
        return received
    }
}
