// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CryptoKit
import Foundation
import VerbinalKit

/// One Research record, as kept in VOSpace (plan 34 V):
/// `.verbinal/research/<key>.json`. The observation's details and the
/// person's note — not its files, nor anything of this Mac (paths,
/// bookmarks). `removedAt` marks a record the person removed, so other
/// devices remove it too; a missing item means nothing.
struct ResearchItem: Codable, Equatable, Sendable {
    static let format = 1

    struct Details: Codable, Equatable, Sendable {
        var publisherID: String
        var collection: String
        var observationID: String
        var targetName: String
        var instrument: String
        var filter: String
        var ra: String
        var dec: String
        var startDate: String
        var calLevel: String
        var thumbnailURL: String?
        var previewURL: String?
        var cutout: CutoutSpec?
    }

    struct Note: Codable, Equatable, Sendable {
        var text: String
        var rating: Int
        var tags: [String]
    }

    var format = ResearchItem.format
    /// The record's identity across devices: its publisher ID, and which
    /// cutout of it.
    var recordKey: String
    /// When it last changed, wherever.
    var changedAt: Date
    var removedAt: Date?
    var details: Details
    var note: Note?

    /// Its file name in the kind's folder: the same on every device.
    static func fileName(for recordKey: String) -> String {
        SHA256.hash(data: Data(recordKey.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    var fileName: String { Self.fileName(for: recordKey) }

    /// What it says, dates aside: two devices that agree have the same.
    var content: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var plain = self
        plain.changedAt = Date(timeIntervalSince1970: 0)
        plain.removedAt = removedAt.map { _ in Date(timeIntervalSince1970: 0) }
        let data = (try? encoder.encode(plain)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(StorageDates.format(date))
        }
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) throws -> ResearchItem {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = StorageDates.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
            }
            return date
        }
        return try decoder.decode(ResearchItem.self, from: data)
    }
}

/// Research on this device, as the sync sees it: its records as items, and
/// the way an item from another device becomes one of them.
protocol ResearchSyncSource: Sendable {
    /// Every record here, as an item.
    func items() async -> [ResearchItem]
    /// Keeps `item` here: a new record without its file, or the record
    /// brought up to it; its note too.
    func apply(_ item: ResearchItem) async
    /// Removes the record `recordKey` from here — another device removed
    /// it. Its notes stay, as when the person removes one.
    func remove(recordKey: String) async
    /// The change log: what a newer change replaced, to be put back.
    func replaced(_ item: ResearchItem, by newer: ResearchItem) async
}

/// Research, kept in VOSpace when the person chooses (plan 34 V): the same
/// records and notes on every device. Each record is one item; the newer
/// change wins, and what it replaced goes to the change log.
struct ResearchKind: StorageKind {
    let id = "research"
    let defaultFolder = ".verbinal/research"
    /// Waits for the person: their notes, their allocation.
    let declaredWhenFound = false
    let source: any ResearchSyncSource
    var now: @Sendable () -> Date = Date.init

    /// Memory's mark of a record this device had at its last sync.
    private static let seen = "seen:"

    /// The folder is readable by anyone: Research waits until it is not.
    static let publicNote = "Research is not synced while .verbinal is readable by anyone; make it private in Storage"

    func sync(_ context: StorageKindContext) async throws -> StorageKindOutcome {
        // Notes are the person's: never into a folder anyone can read.
        if try await context.remote.isPublic(".verbinal") {
            return StorageKindOutcome(note: Self.publicNote)
        }
        var memory = context.memory
        var imported = 0, sent = 0
        let local = Dictionary(await source.items().map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
        let present = Set(context.items.map(\.name))
        var settled: Set<String> = []

        // What changed there.
        for item in context.changed where item.name.hasSuffix(".json") {
            guard let data = try? await context.remote.read("\(context.folder)/\(item.name)"),
                  let theirs = try? ResearchItem.decode(data), theirs.format <= ResearchItem.format else { continue }
            settled.insert(item.name)
            let mine = local[item.name]
            let mineChanged = mine.map { $0.content != memory[item.name] } ?? false
            if let removed = theirs.removedAt {
                if let mine, mineChanged, mine.changedAt > removed {
                    try await send(mine, to: context); sent += 1
                    memory[item.name] = mine.content
                } else {
                    if mine != nil { await source.remove(recordKey: theirs.recordKey); imported += 1 }
                    memory[item.name] = theirs.content
                }
                continue
            }
            guard let mine else {
                await source.apply(theirs); imported += 1
                memory[item.name] = theirs.content
                continue
            }
            if mine.content == theirs.content {
                memory[item.name] = theirs.content
            } else if !mineChanged || theirs.changedAt >= mine.changedAt {
                if mineChanged { await source.replaced(mine, by: theirs) }
                await source.apply(theirs); imported += 1
                memory[item.name] = theirs.content
            } else {
                await source.replaced(theirs, by: mine)
                try await send(mine, to: context); sent += 1
                memory[item.name] = mine.content
            }
        }

        // What changed here.
        for (name, mine) in local where !settled.contains(name) {
            if mine.content != memory[name] || !present.contains(name) {
                try await send(mine, to: context); sent += 1
                memory[name] = mine.content
            }
        }

        // What the person removed here — a record this device had at its
        // last sync, gone now: a mark, for the other devices. Never one this
        // device did not have: a failed import is not a removal.
        for (key, _) in memory where key.hasPrefix(Self.seen) {
            let name = String(key.dropFirst(Self.seen.count))
            guard local[name] == nil else { continue }
            memory.removeValue(forKey: key)
            guard present.contains(name), !settled.contains(name),
                  let data = try? await context.remote.read("\(context.folder)/\(name)"),
                  var theirs = try? ResearchItem.decode(data), theirs.removedAt == nil else { continue }
            theirs.removedAt = now()
            theirs.changedAt = now()
            try await send(theirs, to: context); sent += 1
            memory[name] = theirs.content
        }
        for name in await source.items().map(\.fileName) { memory[Self.seen + name] = "1" }
        return StorageKindOutcome(imported: imported, sent: sent, memory: memory)
    }

    private func send(_ item: ResearchItem, to context: StorageKindContext) async throws {
        try await Initiator.$current.withValue(.app) {
            try await Cause.$current.withValue(Cause(why: "Research is kept in VOSpace, for every device")) {
                try await context.remote.write(item.encoded(), to: "\(context.folder)/\(item.fileName)")
            }
        }
    }
}
