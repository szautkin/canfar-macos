// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Which control an agent meant. An agent names a control in whatever words
/// it has; they must land on exactly one or on none — pointing confidently
/// at the wrong thing is worse than saying the name did not match.
enum UIPointerMatcher {

    /// One thing on screen that can be pointed at.
    struct Target: Sendable, Equatable {
        /// Stable across runs and languages.
        let id: String
        /// What it says to a person — localized, so not the identifier, but
        /// very often what an agent was told to look for.
        let label: String
        /// Where it lives ("search", "settings.agent", …).
        let screen: String
        /// A control a person acts on — what a name means when a caption and
        /// its control share it.
        var control = true
    }

    /// Case, spaces and punctuation (an ellipsis, a colon) are not part of
    /// what somebody meant.
    static func normalise(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The one target meant, or nil when none matched or several did equally
    /// well. Tiers, strongest first, each resolved before the next: the id,
    /// the label, the label's leading part ("CFHT" in "CFHT, 15 items"), a
    /// label containing the words, an id containing them. In a
    /// tier, a caption and the one control it names are one answer: the
    /// control.
    static func best(_ targets: [Target], for query: String) -> Target? {
        let wanted = normalise(query)
        guard !wanted.isEmpty else { return nil }
        let tiers: [(Target) -> Bool] = [
            { normalise($0.id) == wanted },
            { normalise($0.label) == wanted },
            { normalise(lead($0.label)) == wanted },
            { normalise($0.label).contains(wanted) },
            { normalise($0.id).contains(wanted) },
        ]
        for tier in tiers {
            let hits = targets.filter(tier)
            if hits.count == 1 { return hits[0] }
            let controls = hits.filter(\.control)
            if hits.count > 1, controls.count == 1, hits.count - controls.count >= 1 { return controls[0] }
            if hits.count > 1 { return nil }   // two is a question, not an answer
        }
        return nil
    }

    /// A label's leading part: up to its first comma, dash or dot — the
    /// name a person says of "CFHT, 15 items, expanded" or "notebook1,
    /// astroml:latest".
    static func lead(_ label: String) -> String {
        let stops = [",", " — ", " · ", " - ", " ("]
        let cut = stops.compactMap { label.range(of: $0)?.lowerBound }.min()
        return cut.map { String(label[..<$0]) } ?? label
    }

    /// What to offer after a miss: names sharing a word first, then the rest.
    static func candidates(_ targets: [Target], for query: String, limit: Int = 12) -> [Target] {
        let words = Set(query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
        let near = targets.filter { t in words.contains { normalise(t.label).contains($0) || normalise(t.id).contains($0) } }
        let rest = targets.filter { t in !near.contains(t) }
        return Array((near + rest.sorted { $0.id < $1.id }).prefix(limit))
    }
}
