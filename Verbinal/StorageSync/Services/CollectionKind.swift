// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Any collection of the person's work kept in VOSpace, by one rule (plan
/// 36 3.1) — Research, workflows, guides, queries, runs:
/// - each item is a file in the collection's folder;
/// - the newer change wins, and the one it replaced is kept on the Mac
///   where it lost;
/// - a removal travels as a mark, and a device marks only what it had;
/// - fields this build does not know are kept;
/// - nothing moves while `.verbinal` is readable by anyone.
///
/// Each waits until the person chooses to keep it in VOSpace (plan 36 3.2).
struct CollectionKind<Collection: SyncCollection>: StorageKind {
    typealias Item = Collection.Item

    let id: String
    let defaultFolder: String
    let declaredWhenFound = false
    let collection: Collection
    /// Where an item a newer change replaced is kept, on this Mac.
    var replacedFolder = CollectionSync.replacedDirectory
    var changes: ChangeLog = .shared
    var now: @Sendable () -> Date = Date.init

    func sync(_ context: StorageKindContext) async throws -> StorageKindOutcome {
        // The person's words and work: never into a folder anyone can read.
        if try await context.remote.isPublic(".verbinal") {
            return StorageKindOutcome(note: CollectionSync.publicNote)
        }
        var memory = context.memory
        var imported = 0, sent = 0
        let local = Dictionary(await collection.items().map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
        let present = Set(context.items.map(\.name))
        var settled: Set<String> = []

        // What changed there.
        for item in context.changed where item.name.hasSuffix(".json") {
            guard let data = try? await context.remote.read("\(context.folder)/\(item.name)"),
                  let theirs = try? Item.decode(data), theirs.format <= Item.format else { continue }
            settled.insert(item.name)
            let mine = local[item.name]
            let mineChanged = mine.map { $0.content != memory[item.name] } ?? false
            if let removed = theirs.removedAt {
                if let mine, mineChanged, mine.changedAt > removed {
                    try await send(mine, to: context); sent += 1
                    memory[item.name] = mine.content
                } else {
                    if mine != nil { await fromAnotherDevice { await collection.remove(key: theirs.key) }; imported += 1 }
                    memory[item.name] = theirs.content
                }
                continue
            }
            guard let mine else {
                await fromAnotherDevice { await collection.apply(theirs) }; imported += 1
                memory[item.name] = theirs.content
                continue
            }
            if mine.content == theirs.content {
                memory[item.name] = theirs.content
            } else if !mineChanged || theirs.changedAt >= mine.changedAt {
                if mineChanged { keepReplaced(mine) }
                await fromAnotherDevice { await collection.apply(theirs) }; imported += 1
                memory[item.name] = theirs.content
            } else {
                keepReplaced(theirs)
                try await send(mine.keepingUnknown(of: theirs), to: context); sent += 1
                memory[item.name] = mine.content
            }
        }

        // What changed here.
        for (name, mine) in local where !settled.contains(name) {
            if mine.content != memory[name] || !present.contains(name) {
                // What is there may hold fields this build does not know: they go back with it.
                let there = present.contains(name)
                    ? (try? await context.remote.read("\(context.folder)/\(name)")).flatMap { try? Item.decode($0) } : nil
                try await send(there.map { mine.keepingUnknown(of: $0) } ?? mine, to: context); sent += 1
                memory[name] = mine.content
            }
        }

        // What the person removed here — an item this device had at its
        // last sync, gone now: a mark, for the other devices. Never one this
        // device did not have: a failed import is not a removal.
        for (key, _) in memory where key.hasPrefix(CollectionSync.seen) {
            let name = String(key.dropFirst(CollectionSync.seen.count))
            guard local[name] == nil else { continue }
            memory.removeValue(forKey: key)
            guard present.contains(name), !settled.contains(name),
                  let data = try? await context.remote.read("\(context.folder)/\(name)"),
                  var theirs = try? Item.decode(data), theirs.removedAt == nil else { continue }
            theirs.removedAt = now()
            theirs.changedAt = now()
            try await send(theirs, to: context); sent += 1
            memory[name] = theirs.content
        }
        for name in await collection.items().map(\.fileName) { memory[CollectionSync.seen + name] = "1" }
        return StorageKindOutcome(imported: imported, sent: sent, memory: memory)
    }

    private func send(_ item: Item, to context: StorageKindContext) async throws {
        try await Initiator.$current.withValue(.app) {
            try await Cause.$current.withValue(Cause(why: "the person keeps their work in VOSpace, for every device")) {
                try await context.remote.write(item.encoded(), to: "\(context.folder)/\(item.fileName)")
            }
        }
    }

    /// A change another device made, kept here as the app's.
    private func fromAnotherDevice(_ change: () async -> Void) async {
        await Initiator.$current.withValue(.app) {
            await Cause.$current.withValue(Cause(why: "a change from another device")) { await change() }
        }
    }

    /// Kept on this Mac, never in a log: notes and guides are the person's words.
    private func keepReplaced(_ item: Item) {
        let folder = replacedFolder.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(item.fileName.dropLast(5))-\(Int(now().timeIntervalSince1970)).json"
        try? item.encoded().write(to: folder.appendingPathComponent(name), options: .atomic)
        let what = collection.title(of: item)
        Initiator.$current.withValue(.app) {
            Cause.$current.withValue(Cause(why: "the newer change wins; the one it replaced is kept in Verbinal's folder, StorageSync/replaced")) {
                changes.done("sync_\(id)", "\(what): kept the newer of two changes")
            }
        }
    }
}

/// What every collection shares.
enum CollectionSync {
    /// Said when `.verbinal` is readable by anyone: nothing moves until it is not.
    static let publicNote = "Your work is not synced while .verbinal is readable by anyone; make it private in Storage"
    /// Memory's mark of an item this device had at its last sync.
    static let seen = "seen:"

    static var replacedDirectory: URL {
        StorageSyncState.productionDirectory.appendingPathComponent("replaced", isDirectory: true)
    }
}
