// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// `.verbinal/manifest.json` in the person's VOSpace home (plan 34 V): which
/// kinds of Verbinal's data the person keeps there, and where each lives.
/// Kinds, not items: a kind's folder holds its items, and is their
/// inventory. Every Verbinal — this Mac, another, Windows, Linux — reads it
/// at sign-in to know what to sync; `docs/vospace-layout.md` says the same
/// for people and for the other apps.
///
/// Read and written whole. A kind, or a field, this build does not know is
/// kept as it is: another app may have added it.
struct StorageManifest: Equatable, Sendable {
    static let formatName = "verbinal.vospace-manifest"
    static let version = 1
    /// Where it is, from the home.
    static let path = ".verbinal/manifest.json"

    /// One kind, as the manifest declares it.
    struct Kind: Equatable, Sendable {
        var folder: String
        /// The kind's item format.
        var format: Int
        /// When it was first declared.
        var since: Date
        /// Fields this build does not know, kept as they came.
        var other: [String: JSONValue] = [:]
    }

    var kinds: [String: Kind]
    /// Top-level fields this build does not know.
    var other: [String: JSONValue] = [:]

    init(kinds: [String: Kind] = [:]) {
        self.kinds = kinds
    }

    func declares(_ id: String) -> Bool { kinds[id] != nil }

    // MARK: - JSON

    enum Problem: Error, Equatable {
        case notAManifest
        /// Written by a newer Verbinal than this one can read.
        case newer(Int)
    }

    static func decode(_ data: Data) throws -> StorageManifest {
        guard case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .string(formatName)? = root["format"] else { throw Problem.notAManifest }
        if let v = root["version"]?.integer, v > version { throw Problem.newer(v) }
        var manifest = StorageManifest()
        if case .object(let kinds)? = root["kinds"] {
            for (id, value) in kinds {
                guard case .object(var fields) = value, case .string(let folder)? = fields["folder"] else { continue }
                let format = fields["format"]?.integer ?? 1
                var since = Date(timeIntervalSince1970: 0)
                if case .string(let text)? = fields["since"], let date = StorageDates.parse(text) { since = date }
                for known in ["folder", "format", "since"] { fields.removeValue(forKey: known) }
                manifest.kinds[id] = Kind(folder: folder, format: format, since: since, other: fields)
            }
        }
        manifest.other = root.filter { !["format", "version", "kinds"].contains($0.key) }
        return manifest
    }

    func encoded() -> Data {
        var kindsObject: [String: JSONValue] = [:]
        for (id, kind) in kinds {
            var fields = kind.other
            fields["folder"] = .string(kind.folder)
            fields["format"] = .int(kind.format)
            fields["since"] = .string(StorageDates.format(kind.since))
            kindsObject[id] = .object(fields)
        }
        var root = other
        root["format"] = .string(Self.formatName)
        root["version"] = .int(Self.version)
        root["kinds"] = .object(kindsObject)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(JSONValue.object(root))) ?? Data()
    }
}

/// Dates as the manifest and the items write them: ISO 8601, UTC, seconds.
enum StorageDates {
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

extension JSONValue {
    /// A whole number, written either way.
    var integer: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(exactly: value)
        default: nil
        }
    }
}
