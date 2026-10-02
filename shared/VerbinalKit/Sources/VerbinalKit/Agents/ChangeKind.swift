// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

/// What a change does, and to what: the unit the person decides on (Settings
/// ▸ AI Agent ▸ What an assistant may do without asking; plan 30 A). Every
/// tool that changes something is one kind — or, by what it acts on, one of
/// two (a delete of what an assistant made; an upload over a file).
public enum ChangeKind: String, Codable, Sendable, CaseIterable {
    // Adds or changes.
    case notesAndSaved
    case filesOnMac
    case addToStorage
    case allocationSessions
    case allocationBatch
    case sharing
    case standingInstruction
    // Removes, replaces or stops.
    case removeAssistantMade
    case removeNotesAndSaved
    case removeFilesOnMac
    case removeFromStorage
    case stopWork
    case everythingAtOnce

    /// Removes, replaces or stops something: what cannot simply be added back.
    public var isDestructive: Bool {
        switch self {
        case .notesAndSaved, .filesOnMac, .addToStorage, .allocationSessions, .allocationBatch, .sharing,
             .standingInstruction:
            false
        case .removeAssistantMade, .removeNotesAndSaved, .removeFilesOnMac, .removeFromStorage, .stopWork,
             .everythingAtOnce:
            true
        }
    }

    /// Whether the person may allow it. What every later assistant is told
    /// always waits: text an assistant reads could make it plant one.
    public var isSettable: Bool { self != .standingInstruction }

    /// As the person decided (plan 30 A0): what adds goes ahead, sharing
    /// asks; what removes asks, but for what an assistant made.
    public var allowedByDefault: Bool {
        switch self {
        case .notesAndSaved, .filesOnMac, .addToStorage, .allocationSessions, .allocationBatch,
             .removeAssistantMade:
            true
        case .sharing, .standingInstruction, .removeNotesAndSaved, .removeFilesOnMac, .removeFromStorage,
             .stopWork, .everythingAtOnce:
            false
        }
    }

    /// Its name, as the person reads it in Settings and Pending.
    public var title: String {
        switch self {
        case .notesAndSaved: "Notes and saved things on this Mac"
        case .filesOnMac: "Files saved on this Mac"
        case .addToStorage: "Add to your CANFAR storage"
        case .allocationSessions: "Use your CANFAR allocation: sessions and compute"
        case .allocationBatch: "Use your CANFAR allocation: batch jobs and image probes"
        case .sharing: "Sharing: who may read or write your files"
        case .standingInstruction: "What every assistant is told"
        case .removeAssistantMade: "Remove what an assistant made"
        case .removeNotesAndSaved: "Remove notes and saved things on this Mac"
        case .removeFilesOnMac: "Remove files on this Mac"
        case .removeFromStorage: "Remove or replace in your CANFAR storage"
        case .stopWork: "Stop running work on CANFAR"
        case .everythingAtOnce: "Clear or delete everything at once"
        }
    }

    /// One line on what it covers.
    public var summary: String {
        switch self {
        case .notesAndSaved: "Notes, ratings, saved queries, workflows, bookmarks, Research records."
        case .filesOnMac: "Downloads, cutouts, figures and exports, as new files — never over one."
        case .addToStorage: "New files and folders in your VOSpace."
        case .allocationSessions: "Launching and renewing sessions; Remote Compute and the code it runs."
        case .allocationBatch: "Batch jobs, and the probe jobs that find what an image has installed."
        case .sharing: "Who may read or write your VOSpace files and folders."
        case .standingInstruction: "Guide tools and tool descriptions every later assistant reads. Always waits."
        case .removeAssistantMade: "Anything an assistant made, as the session log records it — never yours."
        case .removeNotesAndSaved: "Saved queries, recent searches, workflows, bookmarks, image list entries, probe errors."
        case .removeFilesOnMac: "Downloaded files and their Research records."
        case .removeFromStorage: "Deleting from your VOSpace, or uploading over a file there."
        case .stopWork: "Deleting a running session, or stopping Remote Compute: unsaved work in it is lost."
        case .everythingAtOnce: "Clearing a whole list, archive or storage area, or many sessions in one go."
        }
    }
}

/// What the person allows an assistant to do without asking, kind by kind:
/// **Allowed** applies at once, **Ask me** waits in Pending.
public struct ChangePermissions: Codable, Sendable, Equatable {
    /// The person's choices; a kind not here has its default.
    private var choices: [String: Bool]

    public init(_ choices: [ChangeKind: Bool] = [:]) {
        self.choices = Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value) })
    }

    public static let defaults = ChangePermissions()

    /// Every kind asks: what the old Auto-apply switch, off, meant.
    public static let askForEverything = ChangePermissions(
        Dictionary(uniqueKeysWithValues: ChangeKind.allCases.map { ($0, false) }))

    /// The old Auto-apply switch, as these: on is the defaults, off asks for
    /// everything.
    public static func migrating(autoApplyOn: Bool) -> ChangePermissions {
        autoApplyOn ? .defaults : .askForEverything
    }

    public func allows(_ kind: ChangeKind) -> Bool {
        kind.isSettable && (choices[kind.rawValue] ?? kind.allowedByDefault)
    }

    public mutating func set(_ kind: ChangeKind, allowed: Bool) {
        guard kind.isSettable else { return }
        choices[kind.rawValue] = allowed == kind.allowedByDefault ? nil : allowed
    }

    public var isDefault: Bool { ChangeKind.allCases.allSatisfy { allows($0) == ($0.isSettable && $0.allowedByDefault) } }
}

extension AutoApplyPolicy {
    /// Whether a change of `kind` applies without the person.
    public static func appliesAtOnce(_ kind: ChangeKind, permissions: ChangePermissions) -> Bool {
        permissions.allows(kind)
    }

    /// Why it applied or waits, for the session log and Pending: the
    /// person's own setting, by its name.
    public static func rule(forChange kind: ChangeKind, appliedAtOnce: Bool) -> String {
        if kind == .standingInstruction {
            return "waits in Pending: what every later assistant is told always waits for the person"
        }
        return appliedAtOnce
            ? "applied at once: the person allows \"\(kind.title)\""
            : "waits in Pending: the person asks to approve \"\(kind.title)\""
    }

    /// The sentence a tool's description ends with: its kind, and what the
    /// person's setting does with it now.
    public static func toolSentence(forChange kind: ChangeKind, permissions: ChangePermissions) -> String {
        let what = "A change of the kind \"\(kind.title)\"\(kind.isDestructive ? " (destructive)" : "")."
        if kind == .standingInstruction {
            return what + " It always waits in Pending for the person."
        }
        return what + (permissions.allows(kind)
            ? " The person allows it without asking: it applies at once."
            : " The person asks to approve it: it waits in Pending until they do.")
            + " `get_current_view.permissions` gives every kind."
    }
}
