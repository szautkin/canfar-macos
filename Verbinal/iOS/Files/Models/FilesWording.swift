// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What Files says before it deletes (plan 48): one text for each case, so
/// every confirmation says the same thing about what goes and what stays.
enum FilesWording {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func files(_ count: Int) -> String {
        count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }

    // MARK: - On this device

    /// "Delete 3 files (640 MB)?"
    static func deleteTitle(_ files: [LocalFile]) -> String {
        String(localized: "Delete \(Self.files(files.count)) (\(bytes(FilesRules.bytes(files))))?")
    }

    /// What deleting them means: whether storage still has them.
    static func deleteMeaning(_ files: [LocalFile]) -> String {
        let notInStorage = files.filter { !$0.isInStorage }.count
        let one = files.count == 1
        switch notInStorage {
        case 0:
            return one ? String(localized: "It stays in your storage; only this device's copy goes.")
                : String(localized: "They stay in your storage; only this device's copies go.")
        case files.count:
            return one ? String(localized: "It is not in your storage, so Verbinal cannot download it again.")
                : String(localized: "They are not in your storage, so Verbinal cannot download them again.")
        default:
            return String(localized: "\(notInStorage) of them are not in your storage, so Verbinal cannot download them again; the rest stay there.")
        }
    }

    /// "Delete All Downloads (1.1 GB)?"
    static func clearDownloadsTitle(_ bytes: Int64) -> String {
        String(localized: "Delete All Downloads (\(Self.bytes(bytes)))?")
    }

    static var clearDownloadsMeaning: String {
        String(localized: "Your storage keeps every original. Kept files and files from other apps stay.")
    }

    // MARK: - In storage

    /// "Delete “raw”?"
    static func storageDeleteTitle(name: String) -> String {
        String(localized: "Delete “\(name)”?")
    }

    /// What deleting from storage means: what a folder holds goes with it,
    /// and storage has no trash. `items` is nil when a folder could not be
    /// counted; `limit` is how many a listing returns at most.
    static func storageDeleteMeaning(isFolder: Bool, items: Int?, limit: Int = 500) -> String {
        let undo = String(localized: "This cannot be undone: storage has no trash.")
        guard isFolder else { return String(localized: "It is deleted from your storage.") + " " + undo }
        let holds: String
        switch items {
        case .none: holds = String(localized: "Everything in it is deleted with it.")
        case .some(0): holds = String(localized: "It is empty.")
        case .some(1): holds = String(localized: "It holds 1 item, deleted with it.")
        case .some(let count) where count >= limit:
            holds = String(localized: "It holds \(limit) items or more, all deleted with it.")
        case .some(let count): holds = String(localized: "It holds \(count) items, all deleted with it.")
        }
        return holds + " " + undo
    }
}
