// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One in-flight Storage upload or download. Shared by the status bar and
/// the browser model so upload/download stay on a single progress/cancel path
/// (DRY) instead of parallel `isUploading` / `isDownloading` fields.
struct StorageTransfer: Equatable {
    enum Kind: Equatable {
        case upload
        case download
    }

    var kind: Kind
    var fileName: String
    /// Determinate fraction in `0...1`. Nil when total is unknown.
    var fraction: Double?
    var bytesTransferred: Int64
    var bytesTotal: Int64

    var cancelAccessibilityLabel: String {
        switch kind {
        case .upload: return String(localized: "Cancel upload")
        case .download: return String(localized: "Cancel download")
        }
    }

    var cancelledStatus: String {
        switch kind {
        case .upload: return String(localized: "Upload cancelled")
        case .download: return String(localized: "Download cancelled")
        }
    }

    func progressiveStatus(bytesTransferred: Int64, bytesTotal: Int64) -> String {
        let sentLabel = SharedFormatters.bytes(bytesTransferred)
        if bytesTotal <= 0 {
            switch kind {
            case .upload:
                return String(
                    format: String(localized: "Uploading %@ — %@"),
                    fileName, sentLabel
                )
            case .download:
                return String(
                    format: String(localized: "Downloading %@ — %@"),
                    fileName, sentLabel
                )
            }
        }
        let totalLabel = SharedFormatters.bytes(bytesTotal)
        switch kind {
        case .upload:
            return String(
                format: String(localized: "Uploading %@ — %@ of %@"),
                fileName, sentLabel, totalLabel
            )
        case .download:
            return String(
                format: String(localized: "Downloading %@ — %@ of %@"),
                fileName, sentLabel, totalLabel
            )
        }
    }

    func indeterminateStatus() -> String {
        switch kind {
        case .upload: return String(localized: "Uploading \(fileName)...")
        case .download: return String(localized: "Downloading \(fileName)...")
        }
    }

    func completedStatus() -> String {
        switch kind {
        case .upload: return String(localized: "Uploaded \(fileName)")
        case .download: return String(localized: "Downloaded \(fileName)")
        }
    }
}

/// Caps transfer progress callbacks to ~10 Hz / 1% steps so multi-GB FITS
/// transfers don't flood MainActor with status-bar redraws.
final class TransferProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPublish = Date.distantPast
    private var lastFraction: Double = -1

    private var lastTransferred: Int64 = -1

    func shouldPublish(transferred: Int64, total: Int64) -> Bool {
        let fraction = total > 0 ? Double(transferred) / Double(total) : 0
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let dueByTime = now.timeIntervalSince(lastPublish) >= 0.1
        let dueByStep = fraction - lastFraction >= 0.01 || (total > 0 && transferred >= total)
        // Unknown totals never move `fraction` — publish on byte growth too.
        let dueByBytes = total <= 0 && transferred != lastTransferred
        guard dueByTime || dueByStep || dueByBytes else { return false }
        lastPublish = now
        lastFraction = fraction
        lastTransferred = transferred
        return true
    }
}
