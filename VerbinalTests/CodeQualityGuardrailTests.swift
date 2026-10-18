// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 36, item 0.3: the code keeps its shape as it grows. Each rule
/// starts from the app as it is, its exceptions listed; a list may only
/// shrink. When a test here fails:
/// - a new exception: keep to the rule instead;
/// - "take it off the list": the code now keeps to the rule; remove the entry.
@MainActor
final class CodeQualityGuardrailTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Every Swift file under `folders`, by its path from the repository.
    private static func sources(in folders: [String]) -> [(path: String, text: String)] {
        folders.flatMap { folder -> [(path: String, text: String)] in
            let base = root.appendingPathComponent(folder)
            let found = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            return found.compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (String(url.path.dropFirst(root.path.count + 1)), text)
            }
        }
    }

    // MARK: - Tools live in their areas

    /// The folders a catalogue area's tools belong in (`Verbinal/<folder>/…`).
    /// Areas with no folder of their own — foundational, navigation, control,
    /// sessions — are not checked.
    static let areaFolders: [String: Set<String>] = [
        "search": ["Search"], "queries": ["Search"],
        "research": ["Research"], "downloads": ["Research"],
        "fits": ["FITSViewer", "Marks"], "cube": ["CubeViewer", "Marks"],
        "storage": ["Storage", "StorageSync"],
        "headless": ["BatchJobs", "JobHistory"],
        "discovery": ["ImageDiscovery", "RegistryImages", "CanfarImages"],
        "compute": ["RemoteCompute"],
        "workflows": ["Workflows"],
        "sessionLog": ["AgentSession"],
    ]

    /// Tools that live outside their area: none since plan 36 tier 6. A
    /// tool goes in its area's `MCP/` folder.
    static let toolsOutsideTheirArea: Set<String> = []

    func testEveryToolLivesInItsArea() {
        let sources = Self.sources(in: ["Verbinal"])
        var outside: [String] = []
        for tool in Set(AppState().makeAgentTools().map(\.name)) {
            guard let folders = Self.areaFolders[AIGuideCatalog.categoryID(forTool: tool)] else { continue }
            let defining = sources.filter { $0.text.contains("name: \"\(tool)\"") }
                .map { $0.path.split(separator: "/").dropFirst().first.map(String.init) ?? "" }
            // An alias or a name the scan cannot see is not judged.
            guard !defining.isEmpty, !defining.contains(where: folders.contains) else { continue }
            outside.append(tool)
        }
        let new = Set(outside).subtracting(Self.toolsOutsideTheirArea).sorted()
        XCTAssertEqual(new, [], "a tool outside its area's folder: put it in the area's MCP/ folder")
        let moved = Self.toolsOutsideTheirArea.subtracting(outside).sorted()
        XCTAssertEqual(moved, [], "now in its area: take it off toolsOutsideTheirArea")
    }

    // MARK: - Files keep to their size

    static let budget = 600

    /// Files over the budget today, each with its size as a ceiling: it may
    /// shrink, never grow. Shrink only.
    static let overBudget: [String: Int] = [
        "Verbinal/ImageDiscovery/Services/ImageDiscoveryCoordinator.swift": 1194,
        "Verbinal/ViewModels/AppState.swift": 827,
        "Verbinal/Search/MCP/SearchControlTools.swift": 805,
        "shared/VerbinalKit/Sources/VerbinalKit/Networking/NetworkClient.swift": 719,
        "Verbinal/Services/AgentsService.swift": 695,
        "Verbinal/Views/ContentView.swift": 703,
        "Verbinal/ImageDiscovery/ViewModels/ImageDiscoveryModel.swift": 661,
        "Verbinal/Storage/MCP/VOSpaceWriteTools.swift": 639,
        "Verbinal/FITSViewer/MCP/AppState+FITSTools.swift": 622,
        "Verbinal/CubeViewer/ViewModels/CubeViewerModel.swift": 621,
    ]

    func testFilesKeepToTheirBudget() {
        var problems: [String] = []
        var over: Set<String> = []
        for (path, text) in Self.sources(in: ["Verbinal", "shared/VerbinalKit/Sources"]) {
            let lines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            guard lines > Self.budget else { continue }
            over.insert(path)
            if let ceiling = Self.overBudget[path] {
                if lines > ceiling { problems.append("\(path) grew to \(lines) lines (ceiling \(ceiling)): split it") }
            } else {
                problems.append("\(path) is \(lines) lines, over \(Self.budget): split it by job")
            }
        }
        for path in Self.overBudget.keys where !over.contains(path) {
            problems.append("\(path) is within \(Self.budget) lines now, or gone: take it off overBudget")
        }
        XCTAssertEqual(problems, [])
    }

    // MARK: - Loose state flags (plan 38)

    /// The loose flags plan 38 replaced (47 when it began, 2026-10-13): a
    /// new one is a state written by hand — use Phase or a Machine.
    static let looseFlags = ["isLoading", "errorMessage", "hasError", "loadError", "lastError", "statusMessage", "isBusy"]

    /// The few left, each with why it is not a state to replace.
    static let looseFlagsKept: [String: String] = [
        "Verbinal/ViewModels/AppState.swift statusMessage": "the toolbar's caption: a line of text, read from the sign-in",
        "Verbinal/ViewModels/AuthLifecycleController.swift statusMessage": "the toolbar's caption as the sign-in words it",
        "Verbinal/Storage/ViewModels/StorageBrowserModel.swift statusMessage": "the status line: progress and outcomes in words",
        "Verbinal/Storage/ViewModels/StorageBrowserModel.swift isBusy": "a read of three regions — the listing, a transfer, a delete",
        "Verbinal/CubeViewer/Render/CubeVolumeRenderer.swift lastError": "the Metal renderer's own report, which the cube's volume path takes in",
    ]

    func testLooseStateFlagsAreGoneOrKeptForAReason() throws {
        var found: Set<String> = []
        var problems: [String] = []
        for (path, text) in Self.sources(in: ["Verbinal"]) {
            for flag in Self.looseFlags {
                let pattern = try NSRegularExpression(pattern: "\\bvar\\s+\(flag)\\b")
                guard pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
                let key = "\(path) \(flag)"
                found.insert(key)
                if Self.looseFlagsKept[key] == nil {
                    problems.append("\(key): a loose state flag — use Phase or a Machine (plan 38), or keep it here with why")
                }
            }
        }
        for key in Self.looseFlagsKept.keys where !found.contains(key) {
            problems.append("\(key) is gone: take it off looseFlagsKept")
        }
        XCTAssertEqual(problems.sorted(), [])
    }

    // MARK: - Every result goes through ResultDestination

    /// Files that place a file on the Mac that is not a result to send: a
    /// download of a file already in storage, a session log (the device's),
    /// the Research bundle (its own upload choice), and the folder itself.
    static let placesNotAResult: Set<String> = [
        "Verbinal/Helpers/DownloadsFolder.swift", "Verbinal/Storage/MCP/VOSpaceWriteTools.swift",
        "Verbinal/AgentSession/MCP/SessionLogWriteTools.swift", "Verbinal/Research/MCP/AppState+ResearchTools.swift",
    ]

    /// Plan 36 4.1: a result kept on the Mac goes to the person's storage
    /// too when they choose — so each place that keeps one says so to
    /// `ResultDestination`, or writes it through what does (`FigureFile`,
    /// `DownloadPlacement`).
    func testEveryResultGoesThroughResultDestination() {
        var unsaid: [String] = []
        for (path, text) in Self.sources(in: ["Verbinal"]) where !Self.placesNotAResult.contains(path) {
            guard text.contains("DownloadsFolder.move(") || text.contains("DownloadsFolder.timestampedURL(") else { continue }
            let says = ["ResultDestination.shared.kept(", "FigureFile.write(", "DownloadPlacement.place("].contains { text.contains($0) }
            if !says { unsaid.append(path) }
        }
        XCTAssertEqual(unsaid.sorted(), [], "a result kept on the Mac: tell ResultDestination (plan 36 4.1)")
    }

    // MARK: - One folder for Verbinal's files (plan 40)

    /// Where Application Support is asked for but through `AppSupport`, and why.
    static let applicationSupportKept: [String: String] = [
        "shared/VerbinalKit/Sources/MCPCore/SocketSidecar.swift":
            "the socket's address, where the relay looks for it at fixed paths; a test host never writes it (plan 36 Q2)",
    ]

    func testOnlyAppSupportAsksForApplicationSupport() {
        let asking = Self.sources(in: ["Verbinal", "shared/VerbinalKit/Sources", "VerbinalTests", "shared/VerbinalKit/Tests"])
            .filter { $0.text.contains(".applicationSupport" + "Directory") }.map(\.path)
            .filter { !$0.hasSuffix("Storage/AppSupport.swift") && Self.applicationSupportKept[$0] == nil }
        XCTAssertEqual(asking.sorted(), [], "Application Support through AppSupport.directory, so a test run keeps its files to itself (plan 40)")
    }

    func testATestRunKeepsItsFilesToItself() {
        XCTAssertTrue(AppSupport.isTestHost)
        XCTAssertNotEqual(AppSupport.directory.standardizedFileURL.path, AppSupport.realDirectory.standardizedFileURL.path)
        XCTAssertTrue(AppSupport.directory.path.contains("VerbinalTestRuns"), AppSupport.directory.path)
    }

    // MARK: - Every store is synced, or the device's

    /// Synced through CANFAR storage when the person chooses (plan 34 V, 36
    /// tier 3): Research and its notes, saved and recent searches, guides
    /// for assistants, compute runs, job history, added images, recent
    /// launches and Portal defaults.
    static let synced: Set<String> = [
        "observation", "note", "noteTag", "saved_queries.json", "recent_searches.json",
        "aiGuideTool", "aiToolOverride", "compute_runs.json", "job_history.json", "user_images.json",
        "recent_launches.json", "portal_settings.json", "bookmarks.json", "marks.json",
    ]
    /// Never synced: an assistant's sessions on this Mac, caches, indexes,
    /// the app's own bookkeeping — the jobs launched and not yet ended,
    /// whose records sync once they end — and the notes file read once into
    /// the database.
    static let deviceOnly: Set<String> = [
        "agent_activity.json", "assistant_made.json", "pending_proposals.json", "job_launches.json",
        "file_origins.json", "result_uploads.json",
        "archiveObservation", "portal_image_cache.json", "meta", "noteSearch", "observation_notes.json",
    ]
    /// The person's work not yet synced. Shrink only: everything is, since
    /// plan 36 tier 5 — a new store says which it is.
    static let notSyncedYet: Set<String> = []

    func testEveryStoreIsSyncedOrTheDevices() {
        let text = Self.sources(in: ["Verbinal"]).map(\.text).joined(separator: "\n")
        var found: Set<String> = []
        for pattern in [#"fileName: (?:String = )?"([^"]+\.json)""#, #"create\((?:virtualTable|table): "([A-Za-z]+)""#] {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
            }
        }
        XCTAssertGreaterThan(found.count, 15, "the scan finds the stores")
        let lists = [Self.synced, Self.deviceOnly, Self.notSyncedYet]
        let listed = lists.reduce(Set<String>()) { $0.union($1) }
        XCTAssertEqual(found.subtracting(listed).sorted(), [], "a new store: say whether it is synced or the device's")
        XCTAssertEqual(listed.subtracting(found).sorted(), [], "gone: take it off its list")
        XCTAssertEqual(lists.map(\.count).reduce(0, +), listed.count, "a store is in one list only")
    }

    // MARK: - One store over each file

    /// Each store is made once in the app and handed round. Two over one
    /// file each keep a copy, and the last to write drops the other's:
    /// list_recent_launches had its own Recent Launches, read once, and an
    /// assistant's launches went to a third (the live check of plan 42).
    func testEachStoreIsMadeOnce() {
        let regex = try! NSRegularExpression(pattern: #"\b([A-Z][A-Za-z]*Store)\(\)"#)
        var made: [String: [String]] = [:]
        for (path, text) in Self.sources(in: ["Verbinal"]) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let type = String(text[range])
                // These read UserDefaults on every call: they keep no copy.
                if type.hasPrefix("UserDefaults") { continue }
                made[type, default: []].append(path)
            }
        }
        XCTAssertGreaterThan(made.count, 10, "the scan finds the stores")
        XCTAssertEqual(made.filter { $0.value.count > 1 }.mapValues { $0.sorted() }, [:], "make it once and pass it")
    }
}
