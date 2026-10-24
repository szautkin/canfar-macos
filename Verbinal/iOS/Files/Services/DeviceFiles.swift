// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The folders where Verbinal keeps files on this device, and what can be
/// done with them (plan 48): list, delete, keep, give back to the cache. The
/// one place that knows where each kind lives; the cache's cap and order are
/// `RemoteFileCache`'s. Apple's rules: Caches for what can be downloaded
/// again, Documents for what the person keeps, Documents/Inbox the system's.
struct DeviceFiles: Sendable {
    let cache: RemoteFileCache
    /// Documents/Kept: the person's, seen in the Files app, not backed up (D2).
    let kept: URL
    /// Documents/Inbox: where iOS puts files other apps send. Verbinal reads
    /// and deletes there, and never writes.
    let received: URL

    init(cache: RemoteFileCache = RemoteFileCache(),
         documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.cache = cache
        kept = documents.appendingPathComponent("Kept", isDirectory: true)
        received = documents.appendingPathComponent("Inbox", isDirectory: true)
    }

    func folder(of kind: LocalFileKind) -> URL {
        switch kind {
        case .kept: return kept
        case .downloads: return cache.directory
        case .received: return received
        }
    }

    // MARK: - What there is

    /// Every file, of every kind.
    func list() -> [LocalFile] {
        LocalFileKind.allCases.flatMap(list)
    }

    func list(_ kind: LocalFileKind) -> [LocalFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder(of: kind), includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { item in (item as? URL).flatMap { file(at: $0, kind: kind) } }
    }

    /// The file at `url`, if it is one of Verbinal's.
    func file(at url: URL, kind known: LocalFileKind? = nil) -> LocalFile? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let kind = known ?? kind(of: url),
              let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
        let origin = FileOrigin.read(from: url)
        return LocalFile(url: url, kind: kind, size: Int64(values.fileSize ?? 0),
                         lastOpened: FileOrigin.lastOpened(origin, modified: values.contentModificationDate),
                         origin: origin)
    }

    /// Which kind the file at `url` is, if it is one of Verbinal's.
    func kind(of url: URL) -> LocalFileKind? {
        let path = url.resolvingSymlinksInPath().path
        return LocalFileKind.allCases.first { path.hasPrefix(folder(of: $0).resolvingSymlinksInPath().path + "/") }
    }

    // MARK: - Opening

    /// This device's copy of that version of a storage file — kept, else
    /// downloaded — if there is one; opening it makes it recent.
    func localCopy(of file: FileRef) -> URL? {
        guard case .storage(let path) = file.place else { return nil }
        let kept = list(.kept).first {
            $0.origin?.storagePath == path && $0.origin?.size == file.size && $0.origin?.modified == file.modified
        }
        if let kept {
            FileOrigin.markOpened(kept.url)
            return kept.url
        }
        return cache.cached(file)
    }

    /// Notes that one of Verbinal's files was opened. The person's files
    /// elsewhere, and the system's Inbox, are never written to.
    func noteOpened(_ url: URL) {
        guard let kind = kind(of: url), kind != .received else { return }
        FileOrigin.markOpened(url)
    }

    // MARK: - Changing

    /// Deletes files from this device; a download's folder goes with it. One
    /// that cannot be deleted does not stop the rest.
    func remove(_ files: [LocalFile]) throws {
        var failure: Error?
        for file in files {
            do {
                if file.kind == .downloads {
                    try cache.remove(file.url)
                } else {
                    try FileManager.default.removeItem(at: file.url)
                }
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    /// Keeps a file on this device: moved to Kept, out of the cache's reach
    /// and out of iCloud backup — storage, or the app that sent it, has the
    /// original.
    @discardableResult
    func keep(_ file: LocalFile) throws -> LocalFile {
        guard file.kind != .kept else { return file }
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        var destination = Self.unique(file.name, in: kept)
        try FileManager.default.moveItem(at: file.url, to: destination)
        if file.kind == .downloads { try? cache.remove(file.url) }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
        return LocalFile(url: destination, kind: .kept, size: file.size, lastOpened: file.lastOpened, origin: file.origin)
    }

    /// Gives a kept file back to Downloads, where the cap may trim it. Only a
    /// file that is in storage goes back: it can be downloaded again.
    @discardableResult
    func unkeep(_ file: LocalFile) throws -> LocalFile {
        guard file.kind == .kept, file.isInStorage, let ref = file.fileRef else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: file.url])
        }
        let destination = cache.location(of: ref)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: file.url, to: destination)
        cache.trim(keeping: destination)
        return LocalFile(url: destination, kind: .downloads, size: file.size, lastOpened: file.lastOpened, origin: file.origin)
    }

    /// After a deletion in storage: the copies here of what was at `path`,
    /// or under it, are no longer in storage — and say so when deleted.
    func forgetStorage(under path: String) {
        for file in list(.kept) + list(.downloads) {
            guard var origin = file.origin, let stored = origin.storagePath,
                  stored == path || stored.hasPrefix(path + "/") else { continue }
            origin.storagePath = nil
            try? origin.write(to: file.url)
        }
    }

    /// `name` in `folder`, or "name 2.fits" when that is taken.
    static func unique(_ name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let dot = name.dropFirst().firstIndex(of: ".") ?? name.endIndex
        let stem = name[..<dot], rest = name[dot...]
        var number = 2
        repeat {
            candidate = folder.appendingPathComponent("\(stem) \(number)\(rest)")
            number += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}
