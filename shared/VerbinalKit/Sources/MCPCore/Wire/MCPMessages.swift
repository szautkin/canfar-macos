// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// MCP protocol message shapes — the strongly-typed counterparts to the
/// `params` / `result` JSON values inside JSON-RPC envelopes.
///
/// We type only the messages the bridge actually consumes. Anything else
/// passes through as raw JSON and is rejected at the dispatcher with
/// `methodNotFound`.

// MARK: - Initialize

public struct ClientInfo: Codable, Sendable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct ServerInfo: Codable, Sendable, Equatable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct ServerCapabilities: Codable, Sendable, Equatable {
    public let tools: ToolsCapability?
    public let resources: ResourcesCapability?
    public let logging: LoggingCapability?

    public init(tools: ToolsCapability? = nil,
                resources: ResourcesCapability? = nil,
                logging: LoggingCapability? = nil) {
        self.tools = tools
        self.resources = resources
        self.logging = logging
    }

    public struct ToolsCapability: Codable, Sendable, Equatable {
        public let listChanged: Bool?
        public init(listChanged: Bool? = nil) { self.listChanged = listChanged }
    }
    public struct ResourcesCapability: Codable, Sendable, Equatable {
        public let subscribe: Bool?
        public let listChanged: Bool?
        public init(subscribe: Bool? = nil, listChanged: Bool? = nil) {
            self.subscribe = subscribe
            self.listChanged = listChanged
        }
    }
    public struct LoggingCapability: Codable, Sendable, Equatable {
        public init() {}
    }
}

public struct InitializeParams: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let clientInfo: ClientInfo?
    public let capabilities: JSONValue?  // pass-through; we don't negotiate v1

    public init(protocolVersion: String,
                clientInfo: ClientInfo? = nil,
                capabilities: JSONValue? = nil) {
        self.protocolVersion = protocolVersion
        self.clientInfo = clientInfo
        self.capabilities = capabilities
    }
}

public struct InitializeResult: Codable, Sendable, Equatable {
    public let protocolVersion: String
    public let capabilities: ServerCapabilities
    public let serverInfo: ServerInfo
    public let instructions: String?

    public init(protocolVersion: String,
                capabilities: ServerCapabilities,
                serverInfo: ServerInfo,
                instructions: String? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}

// MARK: - tools/list

public struct ToolDefinitionWire: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ListToolsResult: Codable, Sendable, Equatable {
    public let tools: [ToolDefinitionWire]
    public let nextCursor: String?

    public init(tools: [ToolDefinitionWire], nextCursor: String? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
    }
}

// MARK: - tools/call

public struct CallToolParams: Codable, Sendable {
    public let name: String
    public let arguments: JSONValue?

    public init(name: String, arguments: JSONValue? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

/// One block of MCP `content` — the tool's reply to the agent.
public enum CallToolContent: Codable, Sendable, Equatable {
    case text(String)
    /// Allow opaque JSON content blocks for forward-compatibility with
    /// future MCP content types (image, resource, etc.).
    case other(JSONValue)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try c.decode(String.self, forKey: .text)
            self = .text(text)
        default:
            // Re-encode the whole thing as a JSONValue so callers can
            // inspect; we just don't have a typed accessor for it.
            let raw = try JSONValue(from: decoder)
            self = .other(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .other(let json):
            try json.encode(to: encoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
    }
}

public struct CallToolResult: Codable, Sendable, Equatable {
    public let content: [CallToolContent]
    public let isError: Bool?

    public init(content: [CallToolContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }
}
