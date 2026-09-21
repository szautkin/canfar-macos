// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Normalizes agent-supplied VOSpace paths to the contract the REST
/// client expects: **relative to the user's home**, no leading slash,
/// no `/home/<user>` (or `/arc/home/<user>`) prefix.
///
/// Agents paste paths from `list_vospace_path`, container mounts
/// (`/arc/home/me/…`), and absolute home URIs interchangeably.
/// Prepending `username/` on an already-absolute home path double-nests
/// (`/home/me/home/me/…`) and 404s — the 2026-08-28 QA finding on
/// `get_vospace_node`.
enum VOSpaceRelativePath {
    enum Error: Swift.Error, Equatable {
        case traversal
    }

    /// Strip home prefixes and `..` segments. Empty string is the
    /// user's VOSpace root.
    static func normalize(_ path: String, username: String) throws -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            trimmed = String(trimmed.dropFirst())
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty {
            // Slash-terminated hasPrefix only — a bare `home/user` prefix
            // would also match `home/user2/…`.
            let roots = ["home/\(user)", "arc/home/\(user)"]
            let lower = trimmed.lowercased()
            for root in roots {
                let rootLower = root.lowercased()
                if lower == rootLower {
                    return ""
                }
                if lower.hasPrefix(rootLower + "/") {
                    trimmed = String(trimmed.dropFirst(root.count + 1))
                    break
                }
            }
        }
        if trimmed.hasPrefix("/") {
            trimmed = String(trimmed.dropFirst())
        }
        let parts = trimmed.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.contains("..") else {
            throw Error.traversal
        }
        return parts.joined(separator: "/")
    }
}
