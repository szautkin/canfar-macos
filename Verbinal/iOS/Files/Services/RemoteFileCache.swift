// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CryptoKit
import Foundation

/// Files from storage, downloaded to look at (plan 47 3.4): in Caches, which
/// iOS may empty when space runs short, and under the cap the person chose
/// (plan 48) — the least recently opened go first. A file that changed in
/// storage is a new entry. Each notes where it came from.
struct RemoteFileCache: Sendable {
    let directory: URL
    /// What the cache may hold, read when it trims.
    let cap: @Sendable () -> Int64

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbinal/Remote", isDirectory: true),
         cap: @escaping @Sendable () -> Int64 = { FilesRules.capBytes() }) {
        self.directory = directory
        self.cap = cap
    }

    /// The copy of `file` here, if there is one; opening it makes it recent.
    func cached(_ file: FileRef) -> URL? {
        let url = location(of: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        FileOrigin.markOpened(url)
        return url
    }

    /// Keeps a downloaded file, then trims the cache to its cap.
    func store(_ temporary: URL, as file: FileRef) throws -> URL {
        let destination = location(of: file)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        if case .storage(let path) = file.place {
            try? FileOrigin(storagePath: path, size: file.size, modified: file.modified, opened: Date()).write(to: destination)
        }
        trim(keeping: destination)
        return destination
    }

    /// Where `file` is kept: a folder per file and version, its own name inside.
    func location(of file: FileRef) -> URL {
        let identity = "\(file.id)|\(file.size ?? -1)|\(file.modified?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(file.name)
    }

    /// Removes a file and its folder.
    func remove(_ url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let isEntry = folder.deletingLastPathComponent().resolvingSymlinksInPath().path
            == directory.resolvingSymlinksInPath().path
        try FileManager.default.removeItem(at: isEntry ? folder : url)
    }

    /// Removes the least recently opened files until the rest fit the cap.
    func trim(keeping kept: URL? = nil) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, used: Date)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let used = FileOrigin.lastOpened(FileOrigin.read(from: url), modified: values.contentModificationDate)
            files.append((url, Int64(values.fileSize ?? 0), used))
        }
        var total = files.reduce(0) { $0 + $1.size }
        let cap = cap()
        for file in files.sorted(by: { $0.used < $1.used }) where total > cap {
            guard file.url.resolvingSymlinksInPath() != kept?.resolvingSymlinksInPath() else { continue }
            try? remove(file.url)
            total -= file.size
        }
    }
}
