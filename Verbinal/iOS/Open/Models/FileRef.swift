// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// A FITS file the person opened on iPhone or iPad (plan 47 phase 3): in
/// their CANFAR storage, read where it is, or on this device.
struct FileRef: Codable, Hashable, Identifiable, Sendable {
    enum Place: Codable, Hashable, Sendable {
        /// Relative to the person's home in storage.
        case storage(path: String)
        /// On this device: a security-scoped bookmark to it.
        case device(bookmark: Data)
    }

    let place: Place
    let name: String
    /// Bytes, when known before it is read.
    var size: Int64?
    /// When it last changed, when known: a newer one is not the cached copy.
    var modified: Date?

    var id: String {
        switch place {
        case .storage(let path): return "storage:" + path
        case .device: return "device:" + name + "\(modified?.timeIntervalSince1970 ?? 0)"
        }
    }

    var isRemote: Bool {
        if case .storage = place { return true }
        return false
    }

    /// A local file as a reference: bookmarked, so it opens again after a relaunch.
    static func device(_ url: URL) -> FileRef? {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return FileRef(place: .device(bookmark: bookmark), name: url.lastPathComponent, size: size, modified: nil)
    }

    /// Where a device file is now, if it still is.
    func deviceURL() -> URL? {
        guard case .device(let bookmark) = place else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

/// The files the person opened on this device, newest first: what Open lists
/// under Recent. Kept on the device only.
@Observable
@MainActor
final class iOSRecentFiles {
    static let key = "ios.open.recentFiles"
    static let limit = 20

    private let defaults: UserDefaults
    private(set) var items: [FileRef]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.items = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([FileRef].self, from: $0) } ?? []
    }

    func add(_ file: FileRef) {
        items.removeAll { $0.place == file.place || ($0.id == file.id) }
        items.insert(file, at: 0)
        items = Array(items.prefix(Self.limit))
        save()
    }

    func remove(_ file: FileRef) {
        items.removeAll { $0.id == file.id }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(items), forKey: Self.key)
    }
}
