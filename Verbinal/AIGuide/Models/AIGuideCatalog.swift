// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Static grouping of the built-in MCP tools into logical categories for the AI
/// Guide UI. The mapping is keyed by tool name; any tool not listed falls into
/// ``other`` so a newly-added tool is never silently dropped from the screen
/// (it surfaces under "Other", a visible signal to slot it into a category).
enum AIGuideCatalog {

    /// One widget's worth of tools.
    struct Category: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let systemImage: String
        /// One-line tile copy for the launchpad (UI only; no logic, no MCP).
        let summary: String
    }

    /// Ordered categories — the order the widgets render top-to-bottom.
    static let categories: [Category] = [
        Category(id: "foundational", title: "Foundational",      systemImage: "info.circle",
                 summary: "App identity, auth, service health, and current view."),
        Category(id: "search",       title: "Search & Archive",   systemImage: "magnifyingglass",
                 summary: "Find observations in CADC and VizieR, then fetch their data."),
        Category(id: "queries",      title: "Saved Queries",      systemImage: "bookmark",
                 summary: "Save, recall, and edit reusable ADQL queries."),
        Category(id: "research",     title: "Research & Notes",   systemImage: "note.text",
                 summary: "Inspect downloaded observations and their notes."),
        Category(id: "downloads",    title: "Downloads",          systemImage: "arrow.down.circle",
                 summary: "Pull observations into the local research archive."),
        Category(id: "fits",         title: "FITS",               systemImage: "square.stack.3d.up",
                 summary: "Read FITS headers and WCS; open, steer, and probe the viewer."),
        Category(id: "cube",         title: "Cube Viewer",        systemImage: "cube.transparent",
                 summary: "Open, steer, and probe the 3D spectral-cube viewer."),
        Category(id: "storage",      title: "Storage (VOSpace)",  systemImage: "externaldrive",
                 summary: "Browse, read, upload, and tidy files in VOSpace."),
        Category(id: "sessions",     title: "Sessions",           systemImage: "desktopcomputer",
                 summary: "Launch and manage interactive compute sessions."),
        Category(id: "headless",     title: "Headless / Batch",   systemImage: "terminal",
                 summary: "Submit batch jobs and follow their logs and events."),
        Category(id: "discovery",    title: "Image Discovery",    systemImage: "shippingbox",
                 summary: "Find images by the packages they contain."),
        Category(id: "compute",      title: "AI Compute",         systemImage: "cpu",
                 summary: "Run agent-authored code on a warm remote session."),
        Category(id: "navigation",   title: "View & Navigation",  systemImage: "rectangle.3.group",
                 summary: "Steer the app's views and focus the search field."),
        Category(id: "control",      title: "Agent Control",      systemImage: "slider.horizontal.3",
                 summary: "Inspect and withdraw the agent's pending proposals."),
        Category(id: "workflows",    title: "Workflows",          systemImage: "checklist",
                 summary: "Follow and author reusable research protocols."),
    ]

    /// Fallback bucket for any tool not explicitly categorized.
    static let other = Category(id: "other", title: "Other", systemImage: "ellipsis.circle",
                                summary: "Tools not yet sorted into a category.")

    /// All categories including the fallback, for iteration in the view.
    static var allCategories: [Category] { categories + [other] }

    /// Tool name → category id. Authored from the composition in
    /// `AppState+AgentTools.makeAgentTools()`; kept here so the grouping lives
    /// next to the rest of the AI Guide model layer.
    private static let categoryByTool: [String: String] = [
        // Foundational
        "describe_app": "foundational",
        "list_apps": "foundational",
        "search_tools": "foundational",
        "man": "foundational",
        "copy_to_clipboard": "foundational",
        "list_ui_targets": "navigation",
        "point_at_ui": "navigation",
        "open_settings": "navigation",
        "close_settings": "navigation",
        "get_auth_state": "foundational",
        "get_current_view": "foundational",
        "get_service_health": "foundational",
        // Search & Archive
        "search_observations": "search",
        "export_search_results": "search",
        "load_saved_search": "search",
        "load_recent_search": "search",
        "run_saved_query": "search",
        "vizier_cone_search": "search",
        "resolve_target": "search",
        "get_observation_caom2": "search",
        "get_data_links": "search",
        "get_preview_image": "search",
        "list_recent_searches": "search",
        "rename_recent_search": "search",
        "remove_recent_search": "search",
        "clear_recent_searches": "search",
        // Search form/results control (Windows wire names + Mac aliases)
        "get_search_form": "search",
        "set_search_form": "search",
        "run_search": "search",
        "reset_search_form": "search",
        "cancel_search": "search",
        "describe_tap_schema": "search",
        "validate_adql_query": "search",
        "get_search_constraints": "search",
        "get_data_train_options": "search",
        "set_search_constraints": "search",
        "refresh_data_train": "search",
        "set_adql_query": "search",
        "set_adql_editor": "search",
        "execute_adql_query": "search",
        "select_search_tab": "search",
        "quick_search": "search",
        "get_search_results": "search",
        "set_search_results_view": "search",
        "set_results_view": "search",
        "open_observation_detail": "search",
        "show_search_row_detail": "search",
        "show_observation_detail": "search",
        // Saved Queries
        "list_saved_queries": "queries",
        "get_saved_query": "queries",
        "save_query": "queries",
        "update_saved_query": "queries",
        "delete_saved_query": "queries",
        // Research & Notes
        "list_downloaded_observations": "research",
        "export_research_bundle": "research",
        "get_downloaded_observation": "research",
        "get_observation_notes": "research",
        "update_observation_note": "research",
        "bulk_update_observation_notes": "research",
        // Downloads
        "download_observation": "downloads",
        "download_observations_bulk": "downloads",
        "delete_downloaded_observation": "downloads",
        "clear_research_archive": "downloads",
        // FITS
        "get_fits_header": "fits",
        "get_fits_wcs": "fits",
        "open_fits_file": "fits",
        "choose_viewer": "fits",
        "get_fits_view": "fits",
        "set_fits_view": "fits",
        "fits_goto_coordinate": "fits",
        "probe_fits_pixel": "fits",
        "get_fits_image": "fits",
        "list_fits_bookmarks": "fits",
        "save_fits_bookmark": "fits",
        "delete_fits_bookmark": "fits",
        // FITS viewer parity (UI parity)
        "select_hdu": "fits",
        "fits_auto_cut": "fits",
        "start_blink": "fits",
        "set_blink": "fits",
        "stop_blink": "fits",
        "blink_fits_tabs": "fits",
        "switch_fits_tab": "fits",
        "set_tab_sync": "fits",
        "search_at_crosshair": "fits",
        "export_fits_figure": "fits",
        // Cube Viewer
        "open_cube": "cube",
        "get_cube_view": "cube",
        "get_cube_image": "cube",
        "set_cube_view": "cube",
        "set_cube_camera": "cube",
        "probe_cube_spectrum": "cube",
        "list_recent_cubes": "cube",
        "show_cube_spectrum": "cube",
        "get_cube_channel_profile": "cube",
        "set_cube_transfer": "cube",
        "switch_cube_tab": "cube",
        "export_cube_figure": "cube",
        // Storage (VOSpace)
        "list_vospace_path": "storage",
        "get_vospace_node": "storage",
        "read_vospace_file": "storage",
        "upload_to_vospace": "storage",
        "upload_text_to_vospace": "storage",
        "download_vospace_file": "storage",
        "download_from_vospace": "storage",
        "create_vospace_folder": "storage",
        "vospace_mkdir": "storage",
        "delete_vospace_node": "storage",
        "clear_user_site": "storage",
        "get_storage_quota": "storage",
        "upload_file_to_vospace": "storage",
        "set_vospace_acl": "storage",
        "open_vospace_file": "storage",
        // Sessions
        "list_sessions": "sessions",
        "get_session": "sessions",
        "list_session_types": "sessions",
        "list_session_images": "sessions",
        "list_recent_launches": "sessions",
        "launch_session": "sessions",
        "renew_session": "sessions",
        "delete_session": "sessions",
        "delete_sessions_bulk": "sessions",
        "get_platform_load": "sessions",
        // Sessions parity (UI parity)
        "get_session_events": "sessions",
        "get_session_logs": "sessions",
        "open_session": "sessions",
        // Headless / Batch
        "list_headless_jobs": "headless",
        "get_headless_job": "headless",
        "get_headless_job_logs": "headless",
        "get_headless_job_events": "headless",
        "launch_headless_job": "headless",
        // Image Discovery
        "find_images_with_packages": "discovery",
        "discover_image_packages": "discovery",
        "list_probe_failures": "discovery",
        "get_probe_logs": "discovery",
        "get_image_manifest": "discovery",
        "clear_probe_failures": "discovery",
        // AI Compute
        "run_code": "compute",
        "run_code_output": "compute",
        "start_compute": "compute",
        "stop_compute": "compute",
        // View & Navigation
        "set_search_focus": "navigation",
        "navigate_to": "navigation",
        "list_open_tabs": "navigation",
        "close_active_tab": "navigation",
        "close_tab": "navigation",
        "list_local_folder": "navigation",
        "open_local_file": "navigation",
        "request_folder_access": "navigation",
        // Settings reads
        "get_endpoints": "foundational",
        "get_compute_config": "compute",
        // Agent Control
        "list_guide_tools": "control",
        "set_tool_description": "control",
        "clear_tool_description": "control",
        "add_guide_tool": "control",
        "update_guide_tool": "control",
        "delete_guide_tool": "control",
        "list_pending_proposals": "control",
        "get_proposal_state": "control",
        "withdraw_proposal": "control",
        "start_background_apply": "control",
        "get_job_status": "control",
        "list_events": "control",
        // Workflows
        "list_workflows": "workflows",
        "get_workflow": "workflows",
        "save_workflow": "workflows",
        "update_workflow": "workflows",
        "set_workflow_step": "workflows",
        "use_workflow": "workflows",
        "delete_workflow": "workflows",
    ]

    /// Category id for a tool name, defaulting to ``other``.
    static func categoryID(forTool name: String) -> String {
        categoryByTool[name] ?? other.id
    }

    /// Every explicitly-mapped tool name — the parity guardrail test
    /// cross-checks this against the live registry in both directions.
    static var allMappedToolNames: [String] { Array(categoryByTool.keys) }
}

/// AI Guide user preferences stored in `UserDefaults`. Defined here so the
/// landing tile and the Settings ▸ MCP toggle share one key (no drift).
enum AIGuidePreferences {
    /// Whether the AI Guide tile shows on the landing launchpad. OFF by default —
    /// the tile is hidden until the user enables it in Settings ▸ MCP Clients.
    /// Showing/hiding it only toggles the launchpad shortcut — saved description
    /// overrides and guide tools stay active in the MCP server regardless.
    static let showLandingTileKey = "verbinal.aiGuide.showLandingTile"
}
