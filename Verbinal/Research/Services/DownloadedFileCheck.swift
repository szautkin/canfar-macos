// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Whether a downloaded file holds anything — one check for a download as
/// it lands and for a Research record's file afterwards.
///
/// A download that "succeeded" could still be nothing: the archive's
/// package service answers an observation with no files as a 0-byte body
/// or a tar of 1024 zero bytes, and those were kept as downloads. A file
/// that is nothing is refused when it lands and flagged when it is found.
enum DownloadedFileCheck {
    enum Problem: Equatable, Sendable {
        case missing
        case empty
        /// A tar or zip with no files in it.
        case emptyArchive
        /// Fewer bytes than the server said it would send.
        case shortOf(expected: Int64, got: Int64)
        /// There, but Verbinal may not open it where it is.
        case unreadable

        var message: String {
            switch self {
            case .missing: return String(localized: "The file is not on this Mac any more.")
            case .empty: return String(localized: "The file is empty — the archive sent nothing.")
            case .emptyArchive: return String(localized: "The file is an empty archive — the archive had no files to send.")
            case .unreadable: return String(localized: "Verbinal may not open the file where it is — open it once from Research to give it access again.")
            case .shortOf(let expected, let got):
                return String(localized: "The download stopped short: \(ByteCountFormatter.string(fromByteCount: got, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)).")
            }
        }
    }

    /// What is wrong with the file at `url`, or nil when it holds something.
    /// `expectedBytes` is the length the server announced, when it did.
    static func problem(at url: URL, expectedBytes: Int64? = nil) -> Problem? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) else { return .missing }
        if size == 0 { return .empty }
        if let expectedBytes, expectedBytes > 0, size < expectedBytes { return .shortOf(expected: expectedBytes, got: size) }
        // A file that cannot be opened is not one known to hold something
        // (QA regression run, H2: an empty tar outside the sandbox passed).
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        return isEmptyArchive(head: head, size: size) ? .emptyArchive : nil
    }

    /// A tar whose first block is zeros (its end-of-archive marker, nothing
    /// before it — at most tar's 10240-byte record), or a zip that is only
    /// its end-of-directory record.
    static func isEmptyArchive(head: Data, size: Int64) -> Bool {
        let emptyTar = size % 512 == 0 && (1024...10240).contains(size) && head.count == 512 && head.allSatisfy { $0 == 0 }
        let emptyZip = size == 22 && head.starts(with: [0x50, 0x4B, 0x05, 0x06])
        return emptyTar || emptyZip
    }
}
