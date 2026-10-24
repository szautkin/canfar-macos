// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Where a file Verbinal holds on this device lives (plan 48). A new kind is
/// a new case and its rules; no view changes.
enum LocalFileKind: String, CaseIterable, Identifiable, Sendable {
    /// Kept on this device by the person's choice: Documents/Kept.
    case kept
    /// Downloaded from storage to look at: the cache, which iOS may empty.
    case downloads
    /// Sent by another app (Mail, AirDrop): Documents/Inbox, the system's.
    case received

    var id: String { rawValue }
}

/// Where a file came from, kept with the file itself (an extended
/// attribute), so it follows the file from one kind to another.
struct FileOrigin: Codable, Hashable, Sendable {
    /// Its path in the person's storage, relative to their home; nil when it
    /// is not there (another app sent it, or it was deleted from storage).
    var storagePath: String?
    /// Its size and date in storage when it came down: which version it is.
    var size: Int64?
    var modified: Date?
    /// When the person last opened it here.
    var opened: Date?

    /// When a file was last opened: as noted, else its own date.
    static func lastOpened(_ origin: FileOrigin?, modified: Date?) -> Date {
        origin?.opened ?? modified ?? .distantPast
    }
}

/// A file Verbinal holds on this device.
struct LocalFile: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: LocalFileKind
    let size: Int64
    let lastOpened: Date
    let origin: FileOrigin?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// In the person's storage too: deleting it here loses nothing.
    var isInStorage: Bool { origin?.storagePath != nil }

    /// The storage folder it came from, as "out/" — or nil.
    var storageFolder: String? {
        guard let path = origin?.storagePath else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "/" : folder + "/"
    }

    /// The file as Open and the viewers know it: the storage file when it
    /// came from there, so its page and its copy here stay one.
    var fileRef: FileRef? {
        if let origin, let path = origin.storagePath {
            return FileRef(place: .storage(path: path), name: (path as NSString).lastPathComponent,
                           size: origin.size, modified: origin.modified)
        }
        return FileRef.device(url)
    }
}
