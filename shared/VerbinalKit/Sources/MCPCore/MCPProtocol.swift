// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The MCP versions Verbinal speaks, and what tells them apart — one place
/// for the app's bridge and the relay (plan 25 V).
///
/// - **Modern** (2026-07-28 on): no handshake. Every request declares its
///   version, and the client's identity and capabilities, in `_meta`; every
///   result carries `resultType` and the server's identity; the server
///   answers `server/discover`.
/// - **Legacy** (up to 2025-11-25): the `initialize` handshake.
///
/// A request that declares a version in `_meta` is served as modern; an
/// `initialize` selects legacy for its connection. Both may share one.
public enum MCPProtocol {
    /// The modern versions.
    public static let modern = ["2026-07-28"]
    /// The legacy versions, newest first.
    public static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// Every version, newest first — `server/discover`'s `supportedVersions`.
    public static var supported: [String] { modern + legacy }

    public enum Meta {
        public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
        public static let clientInfo = "io.modelcontextprotocol/clientInfo"
        public static let serverInfo = "io.modelcontextprotocol/serverInfo"
    }

    /// "Unsupported protocol version" (2026-07-28 reserves -32020…-32099).
    public static let unsupportedVersionCode = -32_022

    /// A list result may be kept this long by the client (modern `ttlMs`).
    public static let listTTLMilliseconds = 60_000

    // MARK: - Reading a request

    /// The version a request declares in its `_meta` — modern only.
    public static func declaredVersion(in params: Data?) -> String? {
        meta(of: params)?[Meta.protocolVersion] as? String
    }

    /// The client's identity a request declares in its `_meta`.
    public static func declaredClient(in params: Data?) -> ClientInfo? {
        guard let info = meta(of: params)?[Meta.clientInfo] as? [String: Any],
              let name = info["name"] as? String else { return nil }
        return ClientInfo(name: name, version: info["version"] as? String ?? "")
    }

    private static func meta(of params: Data?) -> [String: Any]? {
        guard let params, let object = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] else { return nil }
        return object["_meta"] as? [String: Any]
    }

    /// The version an `initialize` is answered with: the one asked for when
    /// Verbinal speaks it, else the newest legacy one.
    public static func negotiated(_ requested: String) -> String {
        legacy.contains(requested) ? requested : legacy[0]
    }

    // MARK: - Answering

    /// `-32022`, naming the versions Verbinal speaks.
    public static func unsupported(id: JSONRPCID, requested: String) -> JSONRPCResponse {
        .failure(id: id, error: JSONRPCErrorPayload(
            code: unsupportedVersionCode, message: "Unsupported protocol version",
            data: .object(["supported": .array(supported.map(JSONValue.string)), "requested": .string(requested)])))
    }

    /// `result` as a modern result: `resultType`, the server's identity in
    /// `_meta`, and, for a list, how long it may be kept.
    public static func modernized(_ result: Data, server: ServerInfo, isList: Bool = false) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] else { return result }
        if object["resultType"] == nil { object["resultType"] = "complete" }
        var meta = object["_meta"] as? [String: Any] ?? [:]
        meta[Meta.serverInfo] = ["name": server.name, "version": server.version]
        object["_meta"] = meta
        if isList {
            object["ttlMs"] = listTTLMilliseconds
            object["cacheScope"] = "private"
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? result
    }
}

/// `server/discover`'s answer (2026-07-28): the versions, the capabilities,
/// the instructions, and how long it may be kept. `resultType` and the
/// server's identity are added by `MCPProtocol.modernized`.
public struct DiscoverResult: Encodable, Sendable {
    public let supportedVersions: [String]
    public let capabilities: ServerCapabilities
    public let instructions: String?
    public let ttlMs: Int
    public let cacheScope: String

    public init(capabilities: ServerCapabilities, instructions: String?) {
        self.supportedVersions = MCPProtocol.supported
        self.capabilities = capabilities
        self.instructions = instructions
        self.ttlMs = MCPProtocol.listTTLMilliseconds
        self.cacheScope = "private"
    }
}
