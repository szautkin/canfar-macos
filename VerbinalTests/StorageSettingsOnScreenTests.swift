// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// On screen (plan 40 step 3): Settings ▸ Storage says who paused the
/// sync and where it had got to, with Resume; and the bar has it too.
@MainActor
final class StorageSettingsOnScreenTests: XCTestCase {
    func testAPausedSyncSaysWhoAndWhereWithResume() async throws {
        try await AXReadable.require()
        let state = AppState()
        state.auth.apply(username: "qa-person", userInfo: nil)
        // Signing in starts the real sync: stopped, it says nothing more here.
        state.storageSync.signedOut()
        defer {
            state.storageSync.signedOut()
            TaskRegistry.shared.clearFinished()
        }
        state.storageSync.status = StorageSync.Status(
            hasStorage: true, hasManifest: true, kinds: [], lastSync: nil, lastFailure: nil, running: false,
            paused: .init(by: "assistant", why: "a slow network", at: Date(), kind: "imagePackages", done: 120, total: 288))

        let window = NSWindow(contentRect: NSRect(x: 120, y: 40, width: 640, height: 1100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StorageSettingsTab().environment(state).uiWindowPlace(.settings))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "settings.storage" })
        await source.ready()
        try await Task.sleep(for: .milliseconds(700))
        let snapshot = source.snapshot()
        let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber })
        let names = snapshot.elements(in: ref.index).compactMap(\.name)
        XCTAssertTrue(names.contains("Resume"), "\(names)")
        XCTAssertFalse(names.contains("Sync Now"), "a paused sync is resumed, not synced over")
        XCTAssertTrue(names.contains { $0.contains("Paused by your assistant · Image package lists, 120 of 288") }, "\(names)")

        // The bar has it too, paused, for the person and the tools.
        let task = try XCTUnwrap(TaskRegistry.shared.tasks.last { $0.label == "Syncing with your storage" })
        XCTAssertEqual(task.progress, .paused)
        XCTAssertEqual(task.pause?.by, .assistant)
        XCTAssertEqual(task.done, 120)
        XCTAssertEqual(state.storageSync.taskID, task.id)
    }

    /// Plan 45 F4: each conflict, with its fields and both choices, in
    /// Settings ▸ Storage ▸ Conflicts — for the person and the tools.
    func testConflictsAreShownWithTheirChoices() async throws {
        try await AXReadable.require()
        let state = AppState()
        state.auth.apply(username: "qa-person", userInfo: nil)
        state.storageSync.signedOut()
        defer { state.storageSync.signedOut() }
        let changed = SyncConflict(kind: "savedQueries", key: "q1", fileName: "q1.json", title: "the query \"M31 deep\"",
                                   reason: .bothChanged,
                                   fields: [SyncMerge.Conflict(path: ["adql"], mine: .string("SELECT 1"), theirs: .string("SELECT 2"))],
                                   otherDevice: "Lab Mac", otherChangedAt: nil, at: Date())
        let removed = SyncConflict(kind: "workflows", key: "w1", fileName: "w1.json", title: "the workflow \"Cutouts\"",
                                   reason: .removedHere, fields: [], otherDevice: "Lab Mac", otherChangedAt: nil, at: Date())
        state.storageSync.status = StorageSync.Status(
            hasStorage: true, hasManifest: true, kinds: [], lastSync: nil, lastFailure: nil, running: false,
            conflicts: [changed, removed])

        let window = NSWindow(contentRect: NSRect(x: 120, y: 40, width: 640, height: 1100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StorageSettingsTab().environment(state).uiWindowPlace(.settings))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let source = AXElementSource(screenName: { _, _, _ in "settings.storage" })
        await source.ready()
        try await Task.sleep(for: .milliseconds(700))
        let snapshot = source.snapshot()
        let ref = try XCTUnwrap(snapshot.windows.first { $0.number == window.windowNumber })
        let elements = snapshot.elements(in: ref.index)
        let names = elements.compactMap(\.name)
        XCTAssertTrue(names.contains("Conflicts"), "\(names)")
        XCTAssertTrue(names.contains { $0.contains("Saved queries: the query \"M31 deep\"") }, "\(names)")
        XCTAssertTrue(names.contains { $0.contains("Changed differently on Lab Mac and on this Mac") }, "\(names)")
        XCTAssertTrue(names.contains { $0.contains("adql — this Mac: SELECT 1 · Lab Mac: SELECT 2") }, "\(names)")
        XCTAssertTrue(names.contains { $0.contains("Removed on this Mac, but changed on Lab Mac") }, "\(names)")
        for name in ["Keep This Mac's", "Keep the Other's", "Remove It", "OK"] {
            XCTAssertTrue(names.contains(name), "\(name): \(names)")
        }
        // Each choice by its own target, for point_at_ui.
        let ids = Set(elements.map(\.id))
        for id in ["settings.storage.conflict.savedQueries/q1.json.mine", "settings.storage.conflict.savedQueries/q1.json.theirs",
                   "settings.storage.conflict.workflows/w1.json.mine", "settings.storage.conflict.workflows/w1.json.theirs"] {
            XCTAssertTrue(ids.contains(id), "\(id): \(ids.sorted())")
        }
    }
}
