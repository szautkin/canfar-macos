// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// An item's history, as its file in storage says it (plan 45): which
/// revision it is, which it was made from, which device wrote it, and what
/// it says. What decides between devices — never a clock.
struct SyncRevision: Equatable, Sendable {
    /// 1 when first written, one more with each write, by any device; 0 for
    /// a file written before revisions (plan 44's).
    var rev: Int
    /// The revision it was made from.
    var base: Int
    /// What that revision said: whether it was made from this device's write.
    var baseHash: String?
    /// The installation that wrote it, and its name as the person reads it.
    var device: String?
    var deviceName: String?
    /// What it says (`SyncItem.content`).
    var hash: String

    /// The fields an item carries for its history.
    static let fields: Set<String> = ["rev", "base", "baseHash", "device", "deviceName", "hash"]
    /// What is not an item's own content: its history and dates. Its key and
    /// format, the same on every device, stay in it.
    static let envelope: Set<String> = fields.union(["changedAt", "removedAt"])

    init(rev: Int, base: Int, baseHash: String?, device: String?, deviceName: String?, hash: String) {
        self.rev = rev
        self.base = base
        self.baseHash = baseHash
        self.device = device
        self.deviceName = deviceName
        self.hash = hash
    }

    /// As `item` says it; a file without one is revision 0.
    init(of item: some SyncItem) {
        let stored = item.stored ?? [:]
        func string(_ key: String) -> String? { if case .string(let value)? = stored[key] { value } else { nil } }
        rev = stored["rev"]?.integer ?? 0
        base = stored["base"]?.integer ?? 0
        baseHash = string("baseHash")
        device = string("device")
        deviceName = string("deviceName")
        // A client that does not keep the hash: what the item says is what counts.
        hash = item.content
    }

    /// Its fields, to write beside the item's own.
    var json: [String: JSONValue] {
        var out: [String: JSONValue] = ["rev": .int(rev), "base": .int(base), "hash": .string(hash)]
        if let baseHash { out["baseHash"] = .string(baseHash) }
        if let device { out["device"] = .string(device) }
        if let deviceName { out["deviceName"] = .string(deviceName) }
        return out
    }
}

/// Which installation of Verbinal this is, for an item's history: an id kept
/// with this device's sync state, and the Mac's name.
struct SyncDevice: Codable, Equatable, Sendable {
    let id: String
    let name: String

    static let unknown = SyncDevice(id: "", name: "")

    static func new() -> SyncDevice {
        SyncDevice(id: UUID().uuidString, name: Host.current().localizedName ?? String(localized: "This Mac"))
    }
}

/// What this device keeps of an item between syncs (plan 45): its base —
/// the revision it last synced and what that said, whole, for the merge —
/// and, while its own write is not yet seen standing, what it was made from.
struct SyncBase: Codable, Equatable, Sendable {
    /// Nil: kept by a build before revisions — storage's copy is read.
    var rev: Int?
    var hash: String
    /// The item without its envelope; nil when not kept.
    var content: [String: JSONValue]?
    var removed = false
    /// This device's own write, not yet seen standing in storage.
    var mine = false
    /// What that write was made from: the merge's base should another
    /// device's write have taken its place unseen.
    var parent: Parent?

    struct Parent: Codable, Equatable, Sendable {
        var rev: Int
        var hash: String
        var content: [String: JSONValue]?
        var removed: Bool
    }

    var asParent: Parent { Parent(rev: rev ?? 0, hash: hash, content: content, removed: removed) }

    init(rev: Int?, hash: String, content: [String: JSONValue]?, removed: Bool = false, mine: Bool = false,
         parent: Parent? = nil) {
        self.rev = rev
        self.hash = hash
        self.content = content
        self.removed = removed
        self.mine = mine
        self.parent = parent
    }

    init(_ parent: Parent) {
        self.init(rev: parent.rev, hash: parent.hash, content: parent.content, removed: parent.removed)
    }
}

/// A change the person decides (plan 45): a field two devices changed
/// differently, or an item one removed and the other changed.
struct SyncConflict: Codable, Equatable, Sendable, Identifiable {
    enum Reason: String, Codable, Sendable {
        /// Both changed the same fields differently: storage's stays, this Mac's waits.
        case bothChanged
        /// Removed on another device, changed here: kept, with this Mac's change.
        case removedThere
        /// Removed here, changed on another device: brought back, with its change.
        case removedHere
    }

    /// What the person chooses: this Mac's, or the other device's.
    enum Choice: String, Codable, Sendable {
        case mine, theirs
    }

    let kind: String
    let key: String
    let fileName: String
    /// The item as the person knows it: "the saved query "M31 deep"".
    let title: String
    let reason: Reason
    /// For `bothChanged`: each field, this Mac's value and storage's.
    let fields: [SyncMerge.Conflict]
    /// The other device, as its revision says it.
    let otherDevice: String?
    let otherChangedAt: Date?
    let at: Date

    var id: String { "\(kind)/\(fileName)" }
}
