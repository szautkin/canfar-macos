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
                 summary: "Read FITS headers and WCS; open files in the viewer."),
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
        "get_auth_state": "foundational",
        "get_current_view": "foundational",
        "get_service_health": "foundational",
        // Search & Archive
        "search_observations": "search",
        "vizier_cone_search": "search",
        "resolve_target": "search",
        "get_observation_caom2": "search",
        "get_data_links": "search",
        "get_preview_image": "search",
        "list_recent_searches": "search",
        // Saved Queries
        "list_saved_queries": "queries",
        "get_saved_query": "queries",
        "save_query": "queries",
        "update_saved_query": "queries",
        "delete_saved_query": "queries",
        // Research & Notes
        "list_downloaded_observations": "research",
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
        // Storage (VOSpace)
        "list_vospace_path": "storage",
        "get_vospace_node": "storage",
        "read_vospace_file": "storage",
        "upload_to_vospace": "storage",
        "upload_text_to_vospace": "storage",
        "download_from_vospace": "storage",
        "vospace_mkdir": "storage",
        "delete_vospace_node": "storage",
        "clear_user_site": "storage",
        // Sessions
        "list_sessions": "sessions",
        "get_session": "sessions",
        "list_session_types": "sessions",
        "list_session_images": "sessions",
        "list_recent_launches": "sessions",
        "launch_session": "sessions",
        "delete_session": "sessions",
        "delete_sessions_bulk": "sessions",
        // Headless / Batch
        "list_headless_jobs": "headless",
        "get_headless_job": "headless",
        "get_headless_job_logs": "headless",
        "get_headless_job_events": "headless",
        "launch_headless_job": "headless",
        // Image Discovery
        "find_images_with_packages": "discovery",
        "discover_image_packages": "discovery",
        // AI Compute
        "run_code": "compute",
        "run_code_output": "compute",
        "start_compute": "compute",
        "stop_compute": "compute",
        // View & Navigation
        "set_search_focus": "navigation",
        "navigate_to": "navigation",
        // Agent Control
        "list_pending_proposals": "control",
        "get_proposal_state": "control",
        "withdraw_proposal": "control",
        "list_events": "control",
    ]

    /// Category id for a tool name, defaulting to ``other``.
    static func categoryID(forTool name: String) -> String {
        categoryByTool[name] ?? other.id
    }
}
