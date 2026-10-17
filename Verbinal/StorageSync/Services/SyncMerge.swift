// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MCPCore

/// Three versions of an item, as JSON — the one both sides started from
/// (its base), this Mac's and storage's — merged field by field (plan 45).
/// A field one side changed takes that side's value (decided 2); one both
/// changed alike is that value; one both changed differently keeps
/// storage's, the first to reach it, and this Mac's waits as a conflict for
/// the person (decided 1). Objects merge key by key; a value or a list is
/// one field — a note's text, or its tags. Nothing here knows a clock.
enum SyncMerge {
    /// A field both sides changed differently: where it is, and each side's
    /// value (nil: the side removed it).
    struct Conflict: Codable, Equatable, Sendable {
        let path: [String]
        let mine: JSONValue?
        let theirs: JSONValue?
    }

    struct Result: Equatable, Sendable {
        /// The item as it goes on: storage's value where they conflict.
        let merged: [String: JSONValue]
        let conflicts: [Conflict]
    }

    /// Merges `mine` and `theirs` from `base`; nil: no common past, so every
    /// field both have and that differs is a conflict, and one only a side
    /// has is that side's.
    static func merge(base: [String: JSONValue]?, mine: [String: JSONValue],
                      theirs: [String: JSONValue]) -> Result {
        var conflicts: [Conflict] = []
        let merged = object(base: base ?? [:], mine: mine, theirs: theirs, at: [], &conflicts)
        return Result(merged: merged, conflicts: conflicts)
    }

    private static func object(base: [String: JSONValue], mine: [String: JSONValue], theirs: [String: JSONValue],
                               at path: [String], _ conflicts: inout [Conflict]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in Set(base.keys).union(mine.keys).union(theirs.keys).sorted() {
            if let value = field(base: base[key], mine: mine[key], theirs: theirs[key], at: path + [key], &conflicts) {
                out[key] = value
            }
        }
        return out
    }

    /// One field's value after the merge; nil: absent.
    private static func field(base: JSONValue?, mine: JSONValue?, theirs: JSONValue?,
                              at path: [String], _ conflicts: inout [Conflict]) -> JSONValue? {
        if mine == theirs { return mine }
        // Both still objects: their keys merge one by one.
        if case .object(let mineObject)? = mine, case .object(let theirObject)? = theirs {
            let baseObject: [String: JSONValue]
            if case .object(let object)? = base { baseObject = object } else { baseObject = [:] }
            return .object(object(base: baseObject, mine: mineObject, theirs: theirObject, at: path, &conflicts))
        }
        if mine == base { return theirs }
        if theirs == base { return mine }
        conflicts.append(Conflict(path: path, mine: mine, theirs: theirs))
        return theirs
    }
}
