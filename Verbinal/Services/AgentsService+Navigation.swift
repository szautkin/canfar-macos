// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

extension AgentsService {
    /// Map a proposal `kind` to the AppMode whose view will reflect the
    /// change. Centralizing the table keeps it reviewable; new kinds
    /// either add an entry here or fall through to `nil` (no
    /// follow-on navigation).
    static func navigationTarget(forKind kind: String) -> AppMode? {
        switch kind {
        case "save_query", "update_saved_query", "delete_saved_query":
            return .search
        case "update_observation_note", "bulk_update_observation_notes",
             "download_observation", "download_observations_bulk",
             "delete_downloaded_observation", "clear_research_archive":
            return .research
        case "upload_to_vospace", "upload_text_to_vospace", "upload_file_to_vospace",
             "download_from_vospace",
             "vospace_mkdir", "delete_vospace_node":
            return .storage
        case "launch_session", "delete_session", "delete_sessions_bulk",
             "launch_headless_job", "discover_image_packages":
            return .portal
        // INTENTIONALLY OMITTED — `clear_user_site` falls through to nil.
        // It wipes ~/.local/lib/python3.*/site-packages, which has no
        // user-visible UI surface, so navigating to Storage afterward
        // would mislead rather than help. This is a deliberate gap, not
        // the same defect as the once-missing delete_sessions_bulk /
        // upload_text_to_vospace cases — do not add a navigation here.
        default:
            return nil
        }
    }
}
