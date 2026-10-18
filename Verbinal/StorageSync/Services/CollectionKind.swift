// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore
import VerbinalKit

/// Any collection of the person's work kept in VOSpace, by one rule (plans
/// 36 3.1, 45) — Research, workflows, guides, queries, runs:
/// - each item is a file in the collection's folder, carrying its history
///   (`SyncRevision`): its revision, the one it was made from, the device
///   that wrote it, and what it says;
/// - each device keeps, for each item, the revision it last synced and what
///   that said (`SyncBase`);
/// - this device's copy, its base and storage's decide — never a clock: a
///   change on one side goes to the other; changes on both merge field by
///   field (`SyncMerge`); a field both changed differently keeps storage's,
///   the first to reach it, and this device's waits as a conflict for the
///   person (`SyncConflict`);
/// - a change wins over a removal, and the person is told;
/// - a write is read again just before, and read back after: VOSpace has no
///   "write only if unchanged", so another device's write is never taken for
///   this one's, nor written over unseen;
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
    var changes: ChangeLog = .shared
    var now: @Sendable () -> Date = Date.init

    /// One sync of the collection: what it knows, and what it did.
    private struct Pass {
        let context: StorageKindContext
        var bases: [String: SyncBase]
        var imported = 0
        var sent = 0
        var conflicts: [SyncConflict] = []
    }

    /// Storage's copy of an item, as this sync knows it.
    private enum There {
        /// Not in storage.
        case absent
        /// As this device's base says: unchanged since it last synced.
        case asBase
        case item(Item)
    }

    /// How a decision ended: done, or overtaken by another device's write —
    /// decided again with what it wrote.
    private enum Decided {
        case done
        case overtaken(Item?)
        /// Sent, but storage still shows what was there before: not sent
        /// again now. The next sync finds it standing, or sends it again.
        case unseen
    }

    func sync(_ context: StorageKindContext) async throws -> StorageKindOutcome {
        // The person's words and work: never into a folder anyone can read.
        if try await context.remote.isPublic(".verbinal") {
            return StorageKindOutcome(note: CollectionSync.publicNote)
        }
        var pass = Pass(context: context, bases: CollectionSync.bases(from: context.memory))
        let local = Dictionary(await collection.items().map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
        let present = Set(context.items.map(\.name).filter { $0.hasSuffix(".json") })
        let changed = Set(context.changed.map(\.name).filter { $0.hasSuffix(".json") })

        // What needs a look: changed there, changed or removed here, new on either side.
        let work = Set(local.keys).union(changed).union(pass.bases.keys).sorted().filter { name in
            let base = pass.bases[name]
            if changed.contains(name) || base?.rev == nil || !present.contains(name) { return true }
            guard let base else { return true }
            return local[name].map { $0.content != base.hash } ?? !base.removed
        }
        if !work.isEmpty { await context.progress(0, work.count) }
        for (done, name) in work.enumerated() {
            guard !Task.isCancelled else { break }
            await context.progress(done, work.count)
            try await settle(name, mine: local[name], inStorage: present.contains(name),
                             changedThere: changed.contains(name), &pass)
        }
        // One per item: a decision taken again after another device's write says it once.
        let conflicts = Dictionary(pass.conflicts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return StorageKindOutcome(imported: pass.imported, sent: pass.sent, memory: CollectionSync.memory(of: pass.bases),
                                  conflicts: conflicts.values.sorted { $0.id < $1.id })
    }

    // MARK: - Deciding

    private func settle(_ name: String, mine: Item?, inStorage: Bool, changedThere: Bool, _ pass: inout Pass) async throws {
        var there: There = .absent
        if inStorage {
            if changedThere || pass.bases[name]?.rev == nil {
                // Unreadable now, or a newer build's format: left as it is, for the next sync.
                guard let item = await read(name, pass.context), item.format <= Item.format else { return }
                there = .item(item)
            } else {
                there = .asBase
            }
        }
        // Three tries: a write another device overtakes is decided again with what it wrote.
        for _ in 0..<3 {
            switch try await decide(name, mine: mine, there: there, &pass) {
            case .done, .unseen: return
            case .overtaken(let item): there = item.map(There.item) ?? .absent
            }
        }
    }

    private func decide(_ name: String, mine: Item?, there: There, _ pass: inout Pass) async throws -> Decided {
        let me = pass.context.device
        switch there {
        case .absent:
            guard let mine else {
                pass.bases[name] = nil
                return .done
            }
            // New here — or its file was deleted from storage: written again.
            return try await write(mine, name: name, after: nil, &pass)

        case .asBase:
            guard var base = pass.bases[name] else { return .done }
            if base.mine {
                // This device's last write is still storage's: it stood.
                base.mine = false
                base.parent = nil
                pass.bases[name] = base
            }
            if let mine {
                guard mine.content != base.hash else { return .done }
                return try await write(mine, name: name, after: base.rev, &pass)
            }
            guard !base.removed, let removal = removal(from: base, name: name) else { return .done }
            // Removed here: a mark goes, so the other devices remove it too.
            return try await write(removal, name: name, after: base.rev, &pass)

        case .item(let theirs):
            let revision = SyncRevision(of: theirs)
            var base = pass.bases[name]
            if let written = base, written.mine {
                if revision.hash == written.hash && (revision.device == me.id || revision.rev == written.rev)
                    || (revision.base == written.rev && revision.baseHash == written.hash) {
                    // It stood, or what is there was made from it.
                    base?.mine = false
                    base?.parent = nil
                } else if let parent = written.parent {
                    // Another device's write took its place unseen: merged from
                    // what it was made from, so nothing of it is lost.
                    base = SyncBase(parent)
                } else {
                    base = nil
                }
            }
            if theirs.removedAt != nil {
                guard let mine else {
                    pass.bases[name] = CollectionSync.base(of: theirs)
                    return .done
                }
                if let base, mine.content == base.hash {
                    await fromAnotherDevice { await collection.remove(key: theirs.key) }
                    pass.imported += 1
                    pass.bases[name] = CollectionSync.base(of: theirs)
                    return .done
                }
                // Removed there, changed here: the change wins (decided 3), and the person is told.
                pass.conflicts.append(conflict(.removedThere, name: name, item: mine, revision: revision, theirs: theirs))
                return try await write(mine, name: name, after: revision.rev, &pass)
            }
            guard let mine else {
                if let base, !base.removed {
                    if revision.hash == base.hash, let removal = removal(from: base, name: name) ?? removal(of: theirs) {
                        // Removed here, unchanged there: the removal goes.
                        return try await write(removal, name: name, after: revision.rev, &pass)
                    }
                    // Removed here, changed there: the change wins (decided 3), and the person is told.
                    pass.conflicts.append(conflict(.removedHere, name: name, item: theirs, revision: revision, theirs: theirs))
                }
                await fromAnotherDevice { await collection.apply(theirs) }
                pass.imported += 1
                pass.bases[name] = CollectionSync.base(of: theirs)
                return .done
            }
            if mine.content == revision.hash {
                pass.bases[name] = CollectionSync.base(of: theirs)
                return .done
            }
            if let base {
                let mineChanged = mine.content != base.hash
                let theirsChanged = revision.hash != base.hash || (base.rev.map { $0 != revision.rev } ?? false)
                if !mineChanged {
                    await fromAnotherDevice { await collection.apply(theirs) }
                    pass.imported += 1
                    pass.bases[name] = CollectionSync.base(of: theirs)
                    return .done
                }
                if !theirsChanged {
                    return try await write(mine, name: name, after: revision.rev, &pass)
                }
            }
            // Changed on both sides — or no common past: merged, field by field.
            return try await merge(mine, theirs, revision: revision, base: base, name: name, &pass)
        }
    }

    /// Both changed: what one side changed goes in (decided 2); a field both
    /// changed differently keeps storage's, and this device's waits for the
    /// person (decided 1).
    private func merge(_ mine: Item, _ theirs: Item, revision: SyncRevision, base: SyncBase?, name: String,
                       _ pass: inout Pass) async throws -> Decided {
        let theirContent = CollectionSync.content(of: theirs)
        let result = SyncMerge.merge(base: base?.content, mine: CollectionSync.content(of: mine), theirs: theirContent)
        let told = result.conflicts.filter { !CollectionSync.isBookkeeping($0.path) }
        if !told.isEmpty {
            pass.conflicts.append(conflict(.bothChanged, name: name, item: mine, revision: revision, theirs: theirs,
                                           fields: told))
        }
        if result.merged == theirContent {
            // All of this device's changes are there already, or wait for the person.
            await fromAnotherDevice { await collection.apply(theirs) }
            pass.imported += 1
            pass.bases[name] = CollectionSync.base(of: theirs)
            return .done
        }
        guard let merged = CollectionSync.item(Item.self, from: theirs, content: result.merged, changedAt: now()) else {
            return .done
        }
        await fromAnotherDevice { await collection.apply(merged) }
        pass.imported += 1
        return try await write(merged, name: name, after: revision.rev, &pass)
    }

    // MARK: - Reading and writing, checked

    private func read(_ name: String, _ context: StorageKindContext) async -> Item? {
        guard let data = try? await context.remote.read("\(context.folder)/\(name)") else { return nil }
        return try? Item.decode(data)
    }

    /// Writes `item` as the revision after storage's `after` (nil: none
    /// there). Read just before — another device may have written since this
    /// sync looked — and read back after: only this device's write, standing,
    /// moves its base.
    private func write(_ item: Item, name: String, after storage: Int?, _ pass: inout Pass) async throws -> Decided {
        let context = pass.context
        let current = await read(name, context)
        guard current.map({ SyncRevision(of: $0).rev }) == storage else { return .overtaken(current) }
        // What is there may hold fields this build does not know: they go back with it.
        var item = item
        if item.stored == nil, let current { item = item.keepingUnknown(of: current) }
        let previous = pass.bases[name]
        let revision = SyncRevision(rev: (storage ?? previous?.rev ?? 0) + 1, base: storage ?? 0,
                                    baseHash: current.map(\.content), device: context.device.id,
                                    deviceName: context.device.name, hash: item.content)
        try await send(CollectionSync.encoded(item, with: revision), to: "\(context.folder)/\(name)", context)
        let back = await read(name, context)
        // What was there before, still: the write is not to be read yet
        // (plan 44 F — it was a cached copy). Not another device's: its base
        // stays, and the next sync settles it.
        if back.map(SyncRevision.init(of:)) == current.map(SyncRevision.init(of:)) {
            pass.sent += 1
            return .unseen
        }
        guard let back else { return .overtaken(nil) }
        let written = SyncRevision(of: back)
        guard written.device == context.device.id, written.rev == revision.rev, written.hash == revision.hash else {
            return .overtaken(back)
        }
        pass.sent += 1
        pass.bases[name] = SyncBase(rev: revision.rev, hash: revision.hash, content: CollectionSync.content(of: item),
                                    removed: item.removedAt != nil, mine: true, parent: previous?.asParent)
        return .done
    }

    private func send(_ data: Data, to path: String, _ context: StorageKindContext) async throws {
        try await Initiator.$current.withValue(.app) {
            try await Cause.$current.withValue(Cause(why: "the person keeps their work in VOSpace, for every device")) {
                try await context.remote.write(data, to: path)
            }
        }
    }

    /// A removal mark of what `base` said.
    private func removal(from base: SyncBase, name: String) -> Item? {
        guard let content = base.content,
              let item = CollectionSync.item(Item.self, from: nil, content: content, changedAt: now(),
                                             key: nil, fileName: name) else { return nil }
        return marked(item)
    }

    private func removal(of item: Item) -> Item? { marked(item) }

    private func marked(_ item: Item) -> Item {
        var removed = item
        removed.removedAt = now()
        removed.changedAt = now()
        return removed
    }

    // MARK: - The person's say

    private func conflict(_ reason: SyncConflict.Reason, name: String, item: Item, revision: SyncRevision,
                          theirs: Item, fields: [SyncMerge.Conflict] = []) -> SyncConflict {
        let what = collection.title(of: item)
        Initiator.$current.withValue(.app) {
            Cause.$current.withValue(Cause(why: CollectionSync.why(reason, device: revision.deviceName))) {
                changes.done("sync_\(id)", "\(what): \(CollectionSync.line(reason))")
            }
        }
        return SyncConflict(kind: id, key: item.key, fileName: name, title: what, reason: reason, fields: fields,
                            otherDevice: revision.deviceName, otherChangedAt: theirs.changedAt, at: now())
    }

    /// The person's choice (plan 45, F4). Both changed: this Mac's values go
    /// in as its own change, the next sync sends them; or storage's stay,
    /// already here. Removed there and kept here: removed after all, or kept.
    /// Removed here and brought back: removed again, or kept.
    func resolve(_ conflict: SyncConflict, choosing choice: SyncConflict.Choice) async {
        let current = await collection.items().first { $0.fileName == conflict.fileName }
        switch (conflict.reason, choice) {
        case (.bothChanged, .mine):
            guard let current else { return }
            var content = CollectionSync.content(of: current)
            for field in conflict.fields { CollectionSync.set(field.mine, at: field.path[...], in: &content) }
            guard let chosen = CollectionSync.item(Item.self, from: current, content: content, changedAt: now()) else { return }
            await collection.apply(chosen)
        case (.removedThere, .theirs), (.removedHere, .mine):
            guard let current else { return }
            await collection.remove(key: current.key)
        case (.bothChanged, .theirs), (.removedThere, .mine), (.removedHere, .theirs):
            break
        }
    }

    /// A change another device made, kept here as the app's.
    private func fromAnotherDevice(_ change: () async -> Void) async {
        await Initiator.$current.withValue(.app) {
            await Cause.$current.withValue(Cause(why: "a change from another device")) { await change() }
        }
    }
}

/// What every collection shares.
enum CollectionSync {
    /// Said when `.verbinal` is readable by anyone: nothing moves until it is not.
    static let publicNote = "Your work is not synced while .verbinal is readable by anyone; make it private in Storage"
    private static let basePrefix = "base:"

    /// Fields that only say when something changed: storage's stays, and the
    /// person is not asked about them.
    static func isBookkeeping(_ path: [String]) -> Bool {
        ["changedAt", "modifiedAt", "savedAt", "updatedAt"].contains(path.last ?? "")
    }

    // MARK: Bases, in the kind's memory

    /// The bases kept in `memory`; one a build before revisions kept — the
    /// item's content hash under its name — is a base whose revision is not known.
    static func bases(from memory: [String: String]) -> [String: SyncBase] {
        var bases: [String: SyncBase] = [:]
        for (key, value) in memory {
            if key.hasPrefix(basePrefix) {
                let name = String(key.dropFirst(basePrefix.count))
                if let base = try? JSONDecoder().decode(SyncBase.self, from: Data(value.utf8)) { bases[name] = base }
            } else if !key.contains(":"), bases[key] == nil {
                bases[key] = SyncBase(rev: nil, hash: value, content: nil)
            }
        }
        return bases
    }

    static func memory(of bases: [String: SyncBase]) -> [String: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var memory: [String: String] = [:]
        for (name, base) in bases {
            if let data = try? encoder.encode(base) { memory[basePrefix + name] = String(decoding: data, as: UTF8.self) }
        }
        return memory
    }

    static func base<Item: SyncItem>(of item: Item) -> SyncBase {
        SyncBase(rev: SyncRevision(of: item).rev, hash: item.content, content: content(of: item), removed: item.removedAt != nil)
    }

    // MARK: Items as JSON

    /// What an item says, as JSON, without its envelope: what is merged.
    static func content<Item: SyncItem>(of item: Item) -> [String: JSONValue] {
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: item.encoded()) else { return [:] }
        return object.filter { !SyncRevision.envelope.contains($0.key) }
    }

    /// `item` with `revision` beside what it says.
    static func encoded<Item: SyncItem>(_ item: Item, with revision: SyncRevision) -> Data {
        guard case .object(var object)? = try? JSONDecoder().decode(JSONValue.self, from: item.encoded()) else {
            return item.encoded()
        }
        for (key, value) in revision.json { object[key] = value }
        return (try? SyncCoding.encoder(pretty: true).encode(JSONValue.object(object))) ?? item.encoded()
    }

    /// An item saying `content`, with `from`'s envelope and the fields it
    /// keeps that this build does not know; nil when it does not decode.
    static func item<Item: SyncItem>(_ type: Item.Type, from: Item?, content: [String: JSONValue], changedAt: Date,
                                     key: String? = nil, fileName: String? = nil) -> Item? {
        var object: [String: JSONValue] = [:]
        if let from, case .object(let whole)? = try? JSONDecoder().decode(JSONValue.self, from: from.encoded()) {
            object = whole.filter { SyncRevision.envelope.contains($0.key) && !SyncRevision.fields.contains($0.key) }
        }
        for (field, value) in content { object[field] = value }
        object["changedAt"] = .string(StorageDates.format(changedAt))
        if object["format"] == nil { object["format"] = .int(Item.format) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)), let item = try? Item.decode(data),
              fileName.map({ item.fileName == $0 }) ?? true else { return nil }
        return item
    }

    /// Puts `value` at `path` in `object`; nil removes it.
    static func set(_ value: JSONValue?, at path: ArraySlice<String>, in object: inout [String: JSONValue]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            object[key] = value
            return
        }
        var inner: [String: JSONValue] = [:]
        if case .object(let existing)? = object[key] { inner = existing }
        set(value, at: path.dropFirst(), in: &inner)
        object[key] = .object(inner)
    }

    // MARK: Words for the log

    static func line(_ reason: SyncConflict.Reason) -> String {
        switch reason {
        case .bothChanged: "changed on two devices; storage's stays, this Mac's waits for the person"
        case .removedThere: "removed on another device, changed here: kept"
        case .removedHere: "removed here, changed on another device: brought back"
        }
    }

    static func why(_ reason: SyncConflict.Reason, device: String?) -> String {
        let other = device ?? "another device"
        return switch reason {
        case .bothChanged: "\(other) changed the same fields: the first to reach storage stays, and the person chooses"
        case .removedThere: "\(other) removed it while this Mac changed it: a change is never lost to a removal"
        case .removedHere: "\(other) changed it while this Mac removed it: a change is never lost to a removal"
        }
    }
}
