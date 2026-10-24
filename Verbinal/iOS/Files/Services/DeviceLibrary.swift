// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// The files Verbinal holds on this device, for the views (plan 48): listed
/// by kind, with their totals and what can go. Deleting closes what shows
/// them first. The file work itself is `DeviceFiles`'.
@Observable
@MainActor
final class DeviceLibrary {
    let store: DeviceFiles

    private(set) var files: [LocalFile] = []
    private(set) var problem: String?
    /// Free space on the device, shown beside what Verbinal uses (85F4.1).
    private(set) var available: Int64?

    /// The cap on Downloads, in GB (D5); a lower one trims at once.
    var capGB: Int {
        didSet {
            guard capGB != oldValue else { return }
            UserDefaults.standard.set(capGB, forKey: FilesRules.capKey)
            let cache = store.cache
            Task {
                await Task.detached { cache.trim() }.value
                await reload()
            }
        }
    }

    init(store: DeviceFiles = DeviceFiles()) {
        self.store = store
        capGB = FilesRules.capGB()
    }

    func files(_ kind: LocalFileKind) -> [LocalFile] {
        files.filter { $0.kind == kind }
    }

    /// The bytes of one kind, or of all.
    func bytes(_ kind: LocalFileKind? = nil) -> Int64 {
        FilesRules.bytes(kind.map(files) ?? files)
    }

    /// Not opened in a while: what can go.
    var stale: [LocalFile] { FilesRules.stale(files) }

    func reload() async {
        let store = store
        let (listed, free) = await Task.detached(priority: .userInitiated) {
            (store.list(), Self.availableSpace())
        }.value
        files = listed
        available = free
    }

    /// Deletes files from this device; `closing` first closes the viewers
    /// showing them, so none is left reading a file that is gone.
    func delete(_ doomed: [LocalFile], closing: ([URL]) -> Void) async {
        guard !doomed.isEmpty else { return }
        closing(doomed.map(\.url))
        let store = store
        problem = await Task.detached { () -> String? in
            do { try store.remove(doomed); return nil } catch { return error.localizedDescription }
        }.value
        await reload()
    }

    func clearDownloads(closing: ([URL]) -> Void) async {
        await delete(files(.downloads), closing: closing)
    }

    /// Keep on This Device: by the person's tap, never on its own.
    func keep(_ file: LocalFile) async {
        change { try $0.keep(file) }
        await reload()
    }

    /// Don't Keep: back to Downloads, under the cap.
    func unkeep(_ file: LocalFile) async {
        change { try $0.unkeep(file) }
        await reload()
    }

    /// After a deletion in storage: the copies here say they are not there.
    func forgetStorage(under path: String) async {
        let store = store
        await Task.detached { store.forgetStorage(under: path) }.value
        await reload()
    }

    private func change(_ work: (DeviceFiles) throws -> LocalFile) {
        do {
            _ = try work(store)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Space free for what the person asks to keep (Apple's "important usage").
    nonisolated static func availableSpace() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}
