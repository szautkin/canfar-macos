// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The tool list Verbinal last gave an assistant, kept next to the socket
/// sidecar so the bridge can list the same tools while the app is closed.
public struct ToolManifestCache: Sendable {
    public static let fileName = "mcp-tools.json"

    private let locate: @Sendable () -> URL?

    /// A cache at a known file (tests), or nowhere when `url` is nil.
    public init(url: URL?) {
        locate = { url }
    }

    /// Beside the sidecar the app writes (the App Group container). Resolved
    /// on first use, not here: looking the container up can stall, and the
    /// bridge must answer the handshake first.
    public static func standard() -> ToolManifestCache {
        ToolManifestCache(locate: {
            (try? SocketSidecar.appWriteDirectory())?.appendingPathComponent(fileName)
        })
    }

    private init(locate: @escaping @Sendable () -> URL?) {
        self.locate = locate
    }

    public func load() -> [ToolDefinitionWire] {
        guard let url = locate(), let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(ListToolsResult.self, from: data) else { return [] }
        return list.tools
    }

    public func save(_ tools: [ToolDefinitionWire]) {
        guard let url = locate(), let data = try? JSONEncoder().encode(ListToolsResult(tools: tools)) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
