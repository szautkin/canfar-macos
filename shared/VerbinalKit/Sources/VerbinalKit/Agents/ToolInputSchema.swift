// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// JSON Schema helpers for the MCP tool surface.
///
/// Two bugs this exists to close:
///  1. Every schema said `additionalProperties: false` and nothing enforced
///     it, so a misspelled argument was accepted and ignored.
///  2. One malformed `inputSchema` (not an object) made a client reject the
///     whole server. Arguments are a named map, so the schema must describe
///     an object, `properties` must be a map, and `required` can only name
///     keys that `properties` declares.
public enum ToolInputSchema {

    /// Problems that would make a client reject this schema (or the whole list).
    public static func problems(in schema: JSONValue) -> [String] {
        guard let obj = schema.objectValue else {
            return ["schema must be a JSON object"]
        }
        var issues: [String] = []
        switch obj["type"] {
        case .string("object")?:
            break
        case nil:
            issues.append("missing type: object")
        default:
            issues.append("type must be \"object\" (tool arguments are a named map)")
        }
        let props: [String: JSONValue]
        switch obj["properties"] {
        case nil:
            props = [:]
        case .object(let p)?:
            props = p
        default:
            issues.append("properties must be a map")
            props = [:]
        }
        if let required = obj["required"] {
            guard let names = required.arrayValue else {
                issues.append("required must be an array of property names")
                return issues
            }
            for item in names {
                guard let name = item.stringValue else {
                    issues.append("required entries must be strings")
                    continue
                }
                if props[name] == nil {
                    issues.append("required \"\(name)\" is not declared in properties")
                }
            }
        }
        return issues
    }

    /// Argument keys present in `arguments` that the schema does not declare.
    /// Empty when the schema does not set `additionalProperties: false`.
    ///
    /// Both camelCase and snake_case of a declared name are accepted, matching
    /// the spellings Codable and the Ubuntu/Windows arg bridges honour.
    public static func undeclaredArguments(schema: JSONValue, arguments: Data) -> [String] {
        guard additionalPropertiesForbidden(schema) else { return [] }
        guard let props = properties(schema) else { return [] }
        guard let given = objectKeys(in: arguments) else { return [] }

        var declared = Set<String>()
        for name in props.keys {
            declared.insert(name)
            declared.insert(camelCase(name))
            declared.insert(snakeCase(name))
        }
        return given.filter { !declared.contains($0) }.sorted()
    }

    public static func propertyNames(_ schema: JSONValue) -> [String] {
        properties(schema).map { Array($0.keys).sorted() } ?? []
    }

    // MARK: - Internals

    static func additionalPropertiesForbidden(_ schema: JSONValue) -> Bool {
        schema.objectValue?["additionalProperties"] == .bool(false)
    }

    static func properties(_ schema: JSONValue) -> [String: JSONValue]? {
        schema.objectValue?["properties"]?.objectValue
    }

    /// `null`, empty, or missing arguments parse as an empty object.
    static func objectKeys(in arguments: Data) -> [String]? {
        if arguments.isEmpty { return [] }
        if let text = String(data: arguments, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "null" { return [] }
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: arguments) else {
            return nil
        }
        return value.objectValue.map { Array($0.keys) }
    }

    static func camelCase(_ name: String) -> String {
        let parts = name.split(separator: "_", omittingEmptySubsequences: true)
        guard let first = parts.first else { return name }
        return first.lowercased()
            + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func snakeCase(_ name: String) -> String {
        var out = ""
        for (i, ch) in name.enumerated() {
            if ch.isUppercase {
                if i > 0 { out.append("_") }
                out.append(contentsOf: ch.lowercased())
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
