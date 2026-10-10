// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// A collection on this device, as the sync sees it (plan 36 3.1): its
/// items, and the way an item from another device becomes one of them.
/// Each area brings its own, an adapter beside its store; the store knows
/// nothing of the sync.
protocol SyncCollection: Sendable {
    associatedtype Item: SyncItem
    /// Every item here.
    func items() async -> [Item]
    /// Keeps `item` here: new, or brought up to it.
    func apply(_ item: Item) async
    /// Removes the item `key` from here: another device removed it.
    func remove(key: String) async
    /// The item as the person knows it, for the change log: "M31, 1525350".
    func title(of item: Item) -> String
}

/// A record of an area's list, as kept in VOSpace (plan 36 3.3–3.6): the
/// record as the area keeps it, with its key and dates around it.
struct SyncRecord<Record: Codable & Equatable & Sendable>: SyncItem {
    static var format: Int { 1 }
    var format = 1
    var key: String
    var changedAt: Date
    var removedAt: Date?
    var record: Record
    var stored: [String: JSONValue]?

    enum CodingKeys: String, CodingKey { case format, key, changedAt, removedAt, record }
}

/// An area's list as a synced collection: each record one item, its key
/// and date as the area says. The area keeps its store; this reads and
/// writes only through what it is given.
@MainActor
final class RecordCollection<Record: Codable & Equatable & Sendable>: SyncCollection {
    private let records: () -> [Record]
    private let key: (Record) -> String
    private let changedAt: (Record) -> Date
    private let keep: (Record) -> Void
    private let drop: (String) -> Void
    private let titled: @Sendable (Record) -> String

    /// - Parameters:
    ///   - keep: keeps a record from another device as it is — its dates too.
    ///   - remove: removes the record with that key.
    init(records: @escaping () -> [Record], key: @escaping (Record) -> String,
         changedAt: @escaping (Record) -> Date, keep: @escaping (Record) -> Void,
         remove: @escaping (String) -> Void, title: @escaping @Sendable (Record) -> String) {
        self.records = records
        self.key = key
        self.changedAt = changedAt
        self.keep = keep
        self.drop = remove
        self.titled = title
    }

    func items() async -> [SyncRecord<Record>] {
        records().map { SyncRecord(key: key($0), changedAt: changedAt($0), record: $0) }
    }

    func apply(_ item: SyncRecord<Record>) async { keep(item.record) }

    func remove(key: String) async { drop(key) }

    nonisolated func title(of item: SyncRecord<Record>) -> String { titled(item.record) }
}
