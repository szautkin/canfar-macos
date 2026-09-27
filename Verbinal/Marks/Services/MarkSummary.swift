// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Marks in words: the rows of the Marks list, and what Copy Position puts
/// on the clipboard. Kept apart from the panel because the wording is the
/// part worth testing — a row that does not say *where* a mark is cannot
/// find one whose subject is off screen.
enum MarkSummary {

    static func kindName(_ kind: Mark.Kind) -> String {
        switch kind {
        case .circle: return String(localized: "circle")
        case .rect: return String(localized: "box")
        case .callout: return String(localized: "callout")
        case .text: return String(localized: "text")
        }
    }

    /// The row's headline: its words, or its kind when it has none — an
    /// empty row cannot be clicked on purpose.
    static func title(_ mark: Mark) -> String {
        let text = mark.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(\(kindName(mark.kind)))" : text
    }

    /// Where it is, in the space it is pinned in, named — "512, 384" is
    /// three different places as a pixel, a degree or a voxel.
    static func place(_ anchor: Mark.Anchor) -> String {
        switch anchor.space {
        case .imagePixel:
            return String(localized: "pixel \(Int(anchor.x.rounded())), \(Int(anchor.y.rounded()))")
        case .sky:
            return Sexagesimal.searchPair(ra: anchor.x, dec: anchor.y) ?? "—"
        case .data:
            return String(localized: "voxel \(Int(anchor.x.rounded())), \(Int(anchor.y.rounded())), channel \(Int(anchor.z.rounded()))")
        }
    }

    /// The row's second line. Only an agent's marks say whose they are: a
    /// list where every row ends "by you" says nothing.
    static func detail(_ mark: Mark) -> String {
        let body = "\(kindName(mark.kind)) — \(place(mark.anchor))"
        return mark.author == .agent ? String(localized: "\(body) — by the assistant") : body
    }

    /// The marks whose words or place hold `filter` — someone looking
    /// through thirty marks may remember where one was, not what it said.
    static func filtered(_ marks: [Mark], by filter: String) -> [Mark] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return marks }
        return marks.filter {
            title($0).localizedCaseInsensitiveContains(needle) || detail($0).localizedCaseInsensitiveContains(needle)
        }
    }

    /// Copy Position: the sky as the Search box reads it, when there is one
    /// (`sky`, for a pixel mark on an image with a WCS); otherwise the
    /// pixel or voxel, labelled so it is not taken for degrees.
    static func clipboardText(_ mark: Mark, sky: (ra: Double, dec: Double)?) -> String {
        if let sky, let pair = Sexagesimal.searchPair(ra: sky.ra, dec: sky.dec) { return pair }
        let n = { (v: Double) in String(format: "%.2f", v) }
        switch mark.anchor.space {
        case .sky, .imagePixel: return "x=\(n(mark.anchor.x)), y=\(n(mark.anchor.y)) px"
        case .data: return "x=\(n(mark.anchor.x)), y=\(n(mark.anchor.y)), channel=\(n(mark.anchor.z))"
        }
    }
}
