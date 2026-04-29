// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Hand-rolled JSON-RPC 2.0 envelope types.
///
/// We don't depend on a JSON-RPC library because the MCP wire surface is
/// small and the SDK lock-in cost is higher than maintaining ~150 lines.
///
/// Notes on the protocol:
///   * `id` is *any JSON value* per spec, but in practice peers use
///     either a number or a string. `Null` is the absent-id form for
///     notifications.
///   * `error` and `result` are mutually exclusive on responses; the
///     decoder produces one or the other.

// MARK: - ID

/// JSON-RPC IDs are either an integer, a string, or null (notification).
public enum JSONRPCID: Codable, Hashable, Sendable {
    case int(Int)
    case string(String)
    case null

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCID.self,
                .init(codingPath: decoder.codingPath, debugDescription: "id must be int, string, or null")
            )
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }
}

// MARK: - Request

/// Inbound JSON-RPC request from the agent. `params` is left as raw bytes
/// so each tool deserialises it against its own typed argument struct.
public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let method: String
    /// Raw `params` value, preserved as JSON bytes. May be absent.
    public let params: Data?

    public init(id: JSONRPCID, method: String, params: Data? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        self.id = (try? c.decode(JSONRPCID.self, forKey: .id)) ?? .null
        self.method = try c.decode(String.self, forKey: .method)
        if c.contains(.params) {
            // Re-encode the raw value to bytes for downstream typed parsing.
            let any = try c.decode(JSONValue.self, forKey: .params)
            self.params = try JSONEncoder().encode(any)
        } else {
            self.params = nil
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        try c.encode(method, forKey: .method)
        if let params = params {
            let any = try JSONDecoder().decode(JSONValue.self, from: params)
            try c.encode(any, forKey: .params)
        }
    }
}

// MARK: - Response

public struct JSONRPCErrorPayload: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Outbound response. `result` and `error` are exclusive; we encode one
/// branch or the other.
public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let result: Data?
    public let error: JSONRPCErrorPayload?

    private init(id: JSONRPCID, result: Data?, error: JSONRPCErrorPayload?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success(id: JSONRPCID, result: Data) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    public static func failure(id: JSONRPCID, error: JSONRPCErrorPayload) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: error)
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        self.id = try c.decode(JSONRPCID.self, forKey: .id)
        if let err = try c.decodeIfPresent(JSONRPCErrorPayload.self, forKey: .error) {
            self.error = err
            self.result = nil
        } else if c.contains(.result) {
            let any = try c.decode(JSONValue.self, forKey: .result)
            self.result = try JSONEncoder().encode(any)
            self.error = nil
        } else {
            self.result = nil
            self.error = nil
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        if let err = error {
            try c.encode(err, forKey: .error)
        } else if let result = result {
            let any = try JSONDecoder().decode(JSONValue.self, from: result)
            try c.encode(any, forKey: .result)
        } else {
            // Empty success — encode `result: null`.
            try c.encodeNil(forKey: .result)
        }
    }
}

// MARK: - Standard error codes

public enum JSONRPCErrorCode {
    public static let parseError      = -32_700
    public static let invalidRequest  = -32_600
    public static let methodNotFound  = -32_601
    public static let invalidParams   = -32_602
    public static let internalError   = -32_603

    // Custom (server-defined) range: -32_000 .. -32_099
    public static let serviceUnavailable = -32_000
    public static let sessionNotApproved = -32_001
    public static let serverNotInitialized = -32_002
}

// MARK: - JSONValue

/// Type-erased JSON value used to pass through `params`/`result` without
/// committing to a schema at the envelope layer.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unrecognised JSON value"
        )
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
