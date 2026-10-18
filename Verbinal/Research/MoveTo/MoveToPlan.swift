// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The Move To sheet's choice for the active record, and what it does to
/// each of its files (plan 46): copied or moved between this Mac and the
/// person's storage, or — when every file is in both places — kept in one.
/// Only the active record: a cutout is its own record, not its original.
/// Pure: the sheet shows it, and its button and move_research_files run it.
struct MoveToPlan: Equatable, Sendable {
    /// Where files go.
    enum Place: String, Codable, Sendable, CaseIterable {
        case storage, mac

        var other: Place { self == .storage ? .mac : .storage }
    }

    /// What happens to one file.
    enum Step: Equatable, Sendable {
        case copy(to: Place)
        case move(to: Place)
        /// It is in both places: the copy at `from` goes.
        case remove(from: Place)

        var removes: Place? {
            switch self {
            case .copy: nil
            case .move(let to): to.other
            case .remove(let from): from
            }
        }
    }

    /// Why a file does not go.
    enum Held: Equatable, Sendable {
        /// At the destination already.
        case alreadyThere
        /// The record has it on this Mac, but the file is not there.
        case notOnMac
        /// Refused when it was tried: a different file of that name there,
        /// the copy in storage gone, and the like — in the transfer's words.
        case refused(String)
    }

    /// One of the record's files, as the sheet is given it.
    struct File: Equatable, Sendable {
        let name: String
        let size: Int64?
        let places: FilePlaces
        /// Its copy on this Mac can be read now.
        var onMacReadable = true
    }

    /// One file, as the sheet shows it.
    struct Row: Equatable, Sendable, Identifiable {
        let name: String
        let size: Int64?
        let now: FilePlaces
        /// What it does; nil while it is held.
        let step: Step?
        let held: Held?
        /// The person's: on, unless they unchecked it or it is held.
        let checked: Bool

        var id: String { name }
        /// Where it will be, when checked.
        var after: FilePlaces {
            guard checked, let step else { return now }
            var places = now
            switch step {
            case .copy(let to): places.set(to, true)
            case .move(let to): places.set(to, true); places.set(to.other, false)
            case .remove(let from): places.set(from, false)
            }
            return places
        }
    }

    let files: [File]
    var to: Place
    /// Copy (the person's default) or move.
    var keepCopy: Bool
    /// Files the person unchecked, by name.
    var unchecked: Set<String>
    let signedIn: Bool
    /// Free space in storage, when known.
    var free: Int64?
    /// What the transfer said when a file was tried, by name.
    var refused: [String: String]

    /// The sheet as it opens: toward where the files are not — or, every
    /// file in both places, keeping them in storage — copying. Whether it
    /// keeps one copy is decided as it opens, and stays: a copy just made
    /// does not turn the sheet into a removal.
    init(files: [File], signedIn: Bool, to: Place? = nil, keepCopy: Bool = true, unchecked: Set<String> = [],
         free: Int64? = nil, refused: [String: String] = [:], keepOnly: Bool? = nil) {
        self.files = files
        self.signedIn = signedIn
        self.keepCopy = keepCopy
        self.unchecked = unchecked
        self.free = free
        self.refused = refused
        self.to = to ?? Self.defaultPlace(for: files)
        isKeepOnly = keepOnly ?? (!files.isEmpty && files.allSatisfy { $0.places.onMac && $0.places.inStorage })
    }

    static func defaultPlace(for files: [File]) -> Place {
        if files.contains(where: { $0.places.onMac && !$0.places.inStorage }) { return .storage }
        if files.contains(where: { !$0.places.onMac && $0.places.inStorage }) { return .mac }
        return .storage
    }

    /// Every file was in both places as it opened: the choice is which copy to keep.
    let isKeepOnly: Bool

    var rows: [Row] {
        files.map { file in
            let (step, held) = decide(file)
            return Row(name: file.name, size: file.size, now: file.places, step: step, held: held,
                       checked: step != nil && !unchecked.contains(file.name))
        }
    }

    private func decide(_ file: File) -> (Step?, Held?) {
        if let why = refused[file.name] { return (nil, .refused(why)) }
        let from = to.other
        let here = file.places.has(to), there = file.places.has(from)
        if here {
            // At the destination: kept in one place when that is asked for.
            return there && (isKeepOnly || !keepCopy) ? (.remove(from: from), nil) : (nil, .alreadyThere)
        }
        guard there else { return (nil, .alreadyThere) }
        if from == .mac, !file.onMacReadable { return (nil, .notOnMac) }
        return (keepCopy ? .copy(to: to) : .move(to: to), nil)
    }

    // MARK: - What the button does

    /// The rows the button acts on.
    var active: [Row] { rows.filter { $0.checked && $0.step != nil } }

    /// It removes a copy somewhere: the sheet says so, and the button is a
    /// move's or a removal's.
    var removes: Bool { active.contains { $0.step?.removes != nil } }

    /// The bytes that go to storage, for its free space.
    var toStorage: Int64 {
        active.reduce(0) { sum, row in
            switch row.step {
            case .copy(.storage)?, .move(.storage)?: sum + (row.size ?? 0)
            default: sum
            }
        }
    }

    /// The bytes that come to this Mac.
    var toMac: Int64 {
        active.reduce(0) { sum, row in
            switch row.step {
            case .copy(.mac)?, .move(.mac)?: sum + (row.size ?? 0)
            default: sum
            }
        }
    }

    /// Storage has room for what goes there, or its room is not known.
    var fits: Bool { free.map { toStorage <= $0 } ?? true }

    /// The button can be pressed.
    var canRun: Bool { signedIn && !active.isEmpty && fits }

    /// What the button says, by what it does: "Copy to Storage", "Move 2
    /// Files to This Mac", "Remove from Storage".
    var buttonTitle: String {
        let count = active.count
        if !active.isEmpty, active.allSatisfy({ if case .remove = $0.step { true } else { false } }) {
            return to == .storage
                ? (count == 1 ? String(localized: "Remove from This Mac") : String(localized: "Remove \(count) Files from This Mac"))
                : (count == 1 ? String(localized: "Remove from Storage") : String(localized: "Remove \(count) Files from Storage"))
        }
        switch (to, keepCopy, count > 1) {
        case (.storage, true, false): return String(localized: "Copy to Storage")
        case (.storage, true, true): return String(localized: "Copy \(count) Files to Storage")
        case (.storage, false, false): return String(localized: "Move to Storage")
        case (.storage, false, true): return String(localized: "Move \(count) Files to Storage")
        case (.mac, true, false): return String(localized: "Copy to This Mac")
        case (.mac, true, true): return String(localized: "Copy \(count) Files to This Mac")
        case (.mac, false, false): return String(localized: "Move to This Mac")
        case (.mac, false, true): return String(localized: "Move \(count) Files to This Mac")
        }
    }

    /// What it moves and removes, in a line or two: what moves said quietly,
    /// then the warnings.
    var summary: [String] {
        guard signedIn else { return [String(localized: "Sign in to CANFAR to move files to and from your storage")] }
        guard !active.isEmpty else {
            return [isKeepOnly ? String(localized: "Choose which copy to keep.") : String(localized: "Nothing to move.")]
        }
        return moves + warnings
    }

    /// Where the bytes go.
    private var moves: [String] {
        var lines: [String] = []
        if toStorage > 0 {
            let room = free.map { String(localized: " · \(SharedFormatters.bytes($0)) free") } ?? ""
            lines.append(String(localized: "\(SharedFormatters.bytes(toStorage)) to your storage") + room)
        }
        if toMac > 0 { lines.append(String(localized: "\(SharedFormatters.bytes(toMac)) to this Mac")) }
        return lines
    }

    /// What the person is warned of: storage short of room, a copy removed —
    /// by a move once the other is there; keeping one copy, at once.
    var warnings: [String] {
        guard signedIn, !active.isEmpty else { return [] }
        var lines: [String] = []
        if !fits { lines.append(String(localized: "There is not enough room in your storage for it.")) }
        let moving = active.contains { if case .move = $0.step { true } else { false } }
        switch (active.compactMap({ $0.step?.removes }).first, moving) {
        case (.mac?, true): lines.append(String(localized: "The copy on this Mac is removed once the one in your storage is there."))
        case (.mac?, false): lines.append(String(localized: "The copy on this Mac is removed; the one in your storage stays."))
        case (.storage?, true): lines.append(String(localized: "The copy in your storage is removed once the one on this Mac is there."))
        case (.storage?, false): lines.append(String(localized: "The copy in your storage is removed; the one on this Mac stays."))
        case (nil, _): break
        }
        return lines
    }
}

extension FilePlaces {
    func has(_ place: MoveToPlan.Place) -> Bool { place == .storage ? inStorage : onMac }

    mutating func set(_ place: MoveToPlan.Place, _ value: Bool) {
        if place == .storage { inStorage = value } else { onMac = value }
    }
}

extension MoveToPlan {
    /// The active record's files, each where it is — its own files only: a
    /// cutout's are the cutout and its companions, never its original's.
    static func files(of record: DownloadedObservation) -> [File] {
        record.allFiles.map {
            File(name: $0.name, size: $0.size, places: $0.places, onMacReadable: !$0.places.onMac || $0.local.exists)
        }
    }
}
