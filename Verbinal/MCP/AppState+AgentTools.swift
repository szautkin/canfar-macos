// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Composes the canfar-mac MCP tool surface from `AppState`'s services.
///
/// Each tool here is constructed with the *minimal* set of capabilities
/// it needs — never the whole `AppState`. That keeps tool tests trivial:
/// inject stubs for the closures and call `invoke` directly.
extension AppState {
    func makeAgentTools() -> [any AITool] {
        var tools: [any AITool] = []

        tools.append(DescribeAppTool())

        tools.append(GetAuthStateTool(snapshot: { [weak self] in
            // Snapshot from the main actor each time — auth state can change.
            await MainActor.run {
                let s = self
                let info = s?.userInfo
                let display: String? = {
                    guard let info else { return nil }
                    let parts = [info.firstName, info.lastName].compactMap { $0 }
                    let combined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    return combined.isEmpty ? nil : combined
                }()
                return GetAuthStateTool.Output(
                    isAuthenticated: s?.isAuthenticated ?? false,
                    username: s?.username ?? "",
                    displayName: display
                )
            }
        }))

        return tools
    }
}
