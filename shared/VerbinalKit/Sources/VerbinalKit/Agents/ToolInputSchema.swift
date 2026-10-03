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
///     it, so a misspelled argument was accepted and ignored. ``check(schema:arguments:)``
///     refuses it by name.
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

    /// Outcome of checking one call's arguments against its tool's schema.
    public enum ArgumentCheck: Sendable, Equatable {
        /// Hand these bytes to the tool: the originals, or a copy with each
        /// alias renamed to the spelling the schema declares.
        case accepted(Data)
        /// Refused; the message names the offending keys.
        case refused(String)
    }

    /// Checks `arguments` against a schema that sets
    /// `additionalProperties: false`, and canonicalises aliases — at every
    /// level: an object argument, and each item of an array argument, is
    /// checked against its own schema (plan 30 S2). An item that took a key
    /// its schema does not declare was accepted, decoded with none of its
    /// fields, and wrote nothing while the call said it had.
    ///
    /// The camelCase and snake_case twins of a declared name are accepted —
    /// the Ubuntu and Windows bridges honour both — but tools decode with a
    /// plain `JSONDecoder`, which reads only the declared spelling. So an
    /// alias is *renamed*, not merely allowed: were it passed through, an
    /// optional argument would be accepted here and then silently ignored.
    /// Unknown keys, and one argument given under two spellings, are refused.
    /// Arguments that are not a JSON object pass through for the tool's own
    /// decoder to reject.
    public static func check(schema: JSONValue, arguments: Data) -> ArgumentCheck {
        guard let given = argumentObject(in: arguments) else { return .accepted(arguments) }
        switch canonical(.object(given), schema: schema, path: "") {
        case .refused(let why):
            return .refused(why)
        case .value(let value, let changed):
            guard changed, let data = try? JSONEncoder().encode(value) else { return .accepted(arguments) }
            return .accepted(data)
        }
    }

    private enum Canonical {
        case value(JSONValue, changed: Bool)
        case refused(String)
    }

    /// `value` as `schema` declares it: an object's aliases renamed and, where
    /// the schema forbids others, its unknown keys refused, naming where they
    /// are — and the same for each value it holds and each item of an array.
    private static func canonical(_ value: JSONValue, schema: JSONValue, path: String) -> Canonical {
        if let items = value.arrayValue {
            guard let itemSchema = schema.objectValue?["items"] else { return .value(value, changed: false) }
            var checked: [JSONValue] = []
            var changed = false
            for (index, item) in items.enumerated() {
                switch canonical(item, schema: itemSchema, path: "\(path)[\(index)]") {
                case .refused(let why): return .refused(why)
                case .value(let item, let itemChanged):
                    checked.append(item)
                    changed = changed || itemChanged
                }
            }
            return .value(.array(checked), changed: changed)
        }
        guard let given = value.objectValue, let props = properties(schema) else { return .value(value, changed: false) }
        let forbidden = additionalPropertiesForbidden(schema)
        let spellings = declaredSpellings(props)
        var canonical: [String: JSONValue] = [:]
        var sourceKey: [String: String] = [:]
        var unknown: [String] = []
        var changed = false
        for (key, child) in given {
            guard let name = spellings[key], let childSchema = props[name] else {
                if forbidden { unknown.append(key) } else { canonical[key] = child }
                continue
            }
            if let earlier = sourceKey[name] {
                let both = [earlier, key].sorted().joined(separator: "` and `")
                return .refused("`\(both)` are two spellings of `\(path.isEmpty ? name : "\(path).\(name)")`; pass it once")
            }
            switch Self.canonical(child, schema: childSchema, path: path.isEmpty ? name : "\(path).\(name)") {
            case .refused(let why): return .refused(why)
            case .value(let checked, let childChanged):
                canonical[name] = checked
                changed = changed || childChanged || key != name
            }
            sourceKey[name] = key
        }
        guard unknown.isEmpty else {
            let at = path.isEmpty ? "" : " in `\(path)`"
            return .refused("unknown argument(s)\(at) \(unknown.sorted()); it takes \(Array(props.keys).sorted())")
        }
        return .value(.object(canonical), changed: changed)
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

    /// `null`, empty, or missing arguments parse as an empty object; nil
    /// when the bytes are not a JSON object.
    static func argumentObject(in arguments: Data) -> [String: JSONValue]? {
        if arguments.isEmpty { return [:] }
        if let text = String(data: arguments, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "null" { return [:] }
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: arguments))?.objectValue
    }

    /// Every accepted spelling → the declared name it stands for. A declared
    /// name always maps to itself, even when it is another's twin.
    static func declaredSpellings(_ props: [String: JSONValue]) -> [String: String] {
        var map: [String: String] = [:]
        for name in props.keys { map[name] = name }
        for name in props.keys {
            for alias in [camelCase(name), snakeCase(name)] where map[alias] == nil {
                map[alias] = name
            }
        }
        return map
    }

    /// `foo_bar` → `fooBar`; a name without underscores is returned as is.
    static func camelCase(_ name: String) -> String {
        let parts = name.split(separator: "_", omittingEmptySubsequences: true)
        guard parts.count > 1, let first = parts.first else { return name }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
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
