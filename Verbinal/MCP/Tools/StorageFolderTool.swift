// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - show_storage_folder

/// What came of opening Storage at a folder.
struct StorageFolderShown: Encodable, Sendable, Equatable {
    let shown: Bool
    let folder: String
    let message: String?
}

/// `show_storage_folder` — list_vospace_path reads any folder; this puts
/// one of the person's on screen, as the breadcrumb, a double-click and
/// Remote Compute's "Open Folder in Storage" do.
struct ShowStorageFolderTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable { var folder: String? }

    let definition = AIToolDefinition.withStaticSchema(
        name: "show_storage_folder",
        description: "Open the Storage screen at a folder in the person's own home, so they see it. Pass the folder relative to their home (\".verbinal/exec\", \"data/run1\"), empty for the home itself, or a full \"/<username>/…\" path. Other people's areas and projects are read with list_vospace_path, not shown here. The person must be signed in. Live-applied.",
        schema: #"""
        {
          "type": "object",
          "properties": { "folder": { "type": "string", "description": "Relative to the home, or /<username>/…" } },
          "additionalProperties": false
        }
        """#
    )

    let show: @Sendable (String) async throws -> StorageFolderShown

    func handle(_ args: Args, context: AIToolContext) async throws -> StorageFolderShown {
        try await show(args.folder ?? "")
    }

    /// `folder` relative to `username`'s home, or nil when it is someone
    /// else's: a path from the root must start with `/<username>`.
    static func homeRelative(_ folder: String, username: String) -> String? {
        let text = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard text.hasPrefix("/") else { return path }
        if path == username { return "" }
        return path.hasPrefix(username + "/") ? String(path.dropFirst(username.count + 1)) : nil
    }
}
