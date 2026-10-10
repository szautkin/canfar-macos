// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CryptoKit
import Foundation
import MCPCore

/// One item of a collection kept in VOSpace (plan 36 3.1): one JSON file,
/// named by its key the same on every device. The rule that brings devices
/// in line is `CollectionKind`'s; an item says only what it is, when it
/// last changed, and whether it was removed.
protocol SyncItem: Codable, Equatable, Sendable {
    /// The format this build reads and writes.
    static var format: Int { get }
    var format: Int { get }
    /// Its identity across devices.
    var key: String { get }
    /// When it last changed, wherever.
    var changedAt: Date { get set }
    /// When it was removed: a mark, so the other devices remove it too.
    var removedAt: Date? { get set }
    /// The item as it was read from storage, whole: the fields this build
    /// does not know — a later build's — go back with it (plan 36 1.8).
    var stored: [String: JSONValue]? { get set }
}

extension SyncItem {
    /// Its file name in the collection's folder: the same on every device.
    static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    var fileName: String { Self.fileName(for: key) }

    /// This item, carrying the fields `other` holds that this build does not know.
    func keepingUnknown(of other: Self) -> Self {
        var copy = self
        copy.stored = other.stored
        return copy
    }

    /// What it says, dates of change aside: two devices that agree have the same.
    var content: String {
        var plain = self
        plain.changedAt = Date(timeIntervalSince1970: 0)
        plain.removedAt = removedAt.map { _ in Date(timeIntervalSince1970: 0) }
        plain.stored = nil
        let data = (try? SyncCoding.encoder(pretty: false).encode(plain)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func encoded() -> Data {
        let encoder = SyncCoding.encoder(pretty: true)
        guard let known = try? encoder.encode(self) else { return Data() }
        guard let stored, case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: known) else { return known }
        return (try? encoder.encode(JSONValue.object(SyncCoding.adding(unknownOf: stored, to: object, known: self)))) ?? known
    }

    static func decode(_ data: Data) throws -> Self {
        var item = try SyncCoding.decoder().decode(Self.self, from: data)
        if case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) { item.stored = object }
        return item
    }
}

/// How items are written: dates as storage writes them, whole seconds, so
/// an item read back says what it said.
enum SyncCoding {
    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(StorageDates.format(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = StorageDates.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
            }
            return date
        }
        return decoder
    }

    /// `object` — `value` as this build wrote it — with the fields of
    /// `stored` this build does not know, at the top and in each structure
    /// it holds. A field it knows is `object`'s alone, even when absent
    /// there: an empty optional is a value too.
    static func adding(unknownOf stored: [String: JSONValue], to object: [String: JSONValue],
                       known value: Any) -> [String: JSONValue] {
        var properties: [String: Any] = [:]
        for child in Mirror(reflecting: value).children {
            if let label = child.label { properties[label] = child.value }
        }
        var out = object
        for (key, theirs) in stored {
            guard let property = properties[key] else {
                if out[key] == nil { out[key] = theirs }
                continue
            }
            if case .object(let mine)? = out[key], case .object(let inner) = theirs, let structure = structure(property) {
                out[key] = .object(adding(unknownOf: inner, to: mine, known: structure))
            }
        }
        return out
    }

    /// The structure a property holds, unwrapped from its optional; nil for
    /// a value, a list or a dictionary, whose fields are all its own.
    private static func structure(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional: return mirror.children.first.flatMap { structure($0.value) }
        case .struct, .class: return value
        default: return nil
        }
    }
}
