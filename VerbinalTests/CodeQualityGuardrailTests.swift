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
        "headless": ["JobHistory", "BatchJobs"],
        "discovery": ["ImageDiscovery", "RegistryImages", "CanfarImages"],
        "compute": ["RemoteCompute"],
        "workflows": ["Workflows"],
        "sessionLog": ["AgentSession"],
    ]

    /// Tools that live outside their area today (in `MCP/`); plan 36 tier 6
    /// moves them. Shrink only.
    static let toolsOutsideTheirArea: Set<String> = [
        "annotate_cube", "annotate_fits", "blink_fits_tabs", "bulk_update_observation_notes",
        "cancel_search", "choose_viewer", "clear_annotations", "clear_recent_searches",
        "clear_research_archive", "clear_user_site", "create_vospace_folder", "delete_downloaded_observation",
        "delete_fits_bookmark", "delete_saved_query", "delete_vospace_node", "delete_workflow",
        "describe_tap_schema", "download_cutout", "download_from_vospace", "download_observation",
        "download_observations_bulk", "download_vospace_file", "execute_adql_query", "export_annotations",
        "export_cube_figure", "export_fits_figure", "export_research_bundle", "export_search_results",
        "fits_auto_cut", "fits_goto_coordinate", "get_compute_config", "get_cube_channel_profile",
        "get_cube_image", "get_cube_view", "get_cutout_options", "get_data_links",
        "get_data_train_options", "get_downloaded_observation", "get_fits_header", "get_fits_image",
        "get_fits_spectrum", "get_fits_view", "get_fits_wcs", "get_headless_job",
        "get_headless_job_events", "get_headless_job_logs", "get_observation_caom2", "get_observation_notes",
        "get_preview_image", "get_saved_query", "get_search_constraints", "get_search_form",
        "get_search_results", "get_storage_quota", "get_vospace_node", "get_workflow",
        "launch_headless_job", "list_cube_annotations", "list_downloaded_observations", "list_fits_annotations",
        "list_fits_bookmarks", "list_headless_jobs", "list_recent_searches", "list_saved_queries",
        "list_vospace_path", "list_workflows", "load_recent_search", "load_saved_search",
        "open_cube", "open_fits_file", "open_observation_detail", "open_vospace_file",
        "probe_cube_spectrum", "probe_fits_pixel", "quick_search", "read_vospace_file",
        "refresh_data_train", "remove_annotation", "remove_downloaded_file", "remove_recent_search",
        "rename_recent_search", "reset_search_form", "resolve_target", "run_code",
        "run_code_output", "run_saved_query", "run_search", "save_fits_bookmark",
        "save_observation_to_research", "save_query", "save_workflow", "search_at_crosshair",
        "search_observations", "select_annotation", "select_hdu", "select_search_tab",
        "set_adql_editor", "set_adql_query", "set_blink", "set_cube_camera",
        "set_cube_transfer", "set_cube_view", "set_fits_view", "set_results_view",
        "set_search_constraints", "set_search_form", "set_search_results_view", "set_tab_sync",
        "set_vospace_acl", "set_workflow_step", "show_cube_spectrum", "show_cutout_editor",
        "show_observation_detail", "show_research_observation", "show_search_row_detail", "show_storage_folder",
        "start_blink", "start_compute", "stop_blink", "stop_compute",
        "switch_cube_tab", "switch_fits_tab", "update_annotation", "update_observation_note",
        "update_saved_query", "update_workflow", "upload_file_to_vospace", "upload_text_to_vospace",
        "upload_to_vospace", "use_workflow", "validate_adql_query", "vizier_cone_search",
        "vospace_mkdir",
    ]

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
        "Verbinal/ImageDiscovery/Services/ImageDiscoveryCoordinator.swift": 1227,
        "Verbinal/ViewModels/AppState.swift": 1175,
        "Verbinal/MCP/AppState+SearchTools.swift": 1162,
        "Verbinal/MCP/Tools/HeadlessAgentTools.swift": 806,
        "Verbinal/MCP/Tools/SearchControlTools.swift": 805,
        "Verbinal/ViewModels/SessionLaunchModel.swift": 803,
        "Verbinal/Views/SettingsView.swift": 782,
        "Verbinal/FITSViewer/ViewModels/FITSViewerModel.swift": 748,
        "shared/VerbinalKit/Sources/VerbinalKit/Networking/NetworkClient.swift": 733,
        "Verbinal/Services/AgentsService.swift": 695,
        "Verbinal/Views/ContentView.swift": 703,
        "Verbinal/ImageDiscovery/ViewModels/ImageDiscoveryModel.swift": 665,
        "Verbinal/MCP/Tools/VOSpaceWriteTools.swift": 639,
        "Verbinal/MCP/AppState+FITSTools.swift": 633,
        "Verbinal/CubeViewer/ViewModels/CubeViewerModel.swift": 621,
        "Verbinal/MCP/Tools/CubeViewerControlTools.swift": 619,
        "Verbinal/CubeViewer/Views/CubeRenderControlsView.swift": 612,
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

    // MARK: - Every store is synced, or the device's

    /// Synced through CANFAR storage (plan 34 V): Research and its notes.
    static let synced: Set<String> = ["downloaded_observations.json", "note", "noteTag"]
    /// Never synced: an assistant's sessions on this Mac, caches, indexes,
    /// the app's own bookkeeping, and the notes file read once into the database.
    static let deviceOnly: Set<String> = [
        "agent_activity.json", "assistant_made.json", "pending_proposals.json",
        "archiveObservation", "portal_image_cache.json", "meta", "noteSearch", "observation_notes.json",
    ]
    /// The person's work not yet synced: plan 36 tiers 3–5. Shrink only.
    static let notSyncedYet: Set<String> = [
        "saved_queries.json", "recent_searches.json", "bookmarks.json", "marks.json",
        "compute_runs.json", "job_history.json", "job_launches.json", "user_images.json",
        "recent_launches.json", "portal_settings.json", "aiGuideTool", "aiToolOverride", "observation",
    ]

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
}
