// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Where Verbinal keeps its files: Application Support, as every store has
/// read it (plan 40). In a process XCTest runs — the app as a test host, or
/// a package's tests — a folder of that run's own in the temporary
/// directory instead: tests had left about 9,600 files in the person's
/// Application Support and the app's container. The one place that asks
/// for `.applicationSupportDirectory`; a guardrail holds that.
public enum AppSupport {
    /// XCTest runs this process.
    public static let isTestHost: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil

    /// Application Support, or a test run's own.
    public static let directory: URL = isTestHost ? testRunDirectory() : realDirectory

    /// The user's Application Support — the app's container's, sandboxed.
    public static var realDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Runs older than this are removed when a new one starts; one going on
    /// beside it is younger.
    static let oldRun: TimeInterval = 6 * 3600

    private static func testRunDirectory() -> URL {
        let files = FileManager.default
        let runs = files.temporaryDirectory.appendingPathComponent("VerbinalTestRuns", isDirectory: true)
        let now = Date()
        let left = (try? files.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in left {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > oldRun { try? files.removeItem(at: folder) }
        }
        let mine = runs.appendingPathComponent("run-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
                                               isDirectory: true)
        try? files.createDirectory(at: mine, withIntermediateDirectories: true)
        return mine
    }
}
