// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Characters that look like code and are not: what a document, a chat or
/// a web page leaves in code pasted into the Run code box. Python and Bash
/// stop at them — `print(“Hello”)` is a syntax error on the session. Fixed
/// only when the person asks: inside a string, a curly quote or a dash may
/// be meant.
enum PastedCode {
    enum Kind: CaseIterable, Sendable {
        case quotes, dashes, ellipses, spaces, invisible, lineSeparators

        /// What the Run code box calls them, in a list.
        var title: String {
            switch self {
            case .quotes: String(localized: "curly quotes")
            case .dashes: String(localized: "typographic dashes")
            case .ellipses: String(localized: "ellipses (…)")
            case .spaces: String(localized: "special spaces")
            case .invisible: String(localized: "invisible characters")
            case .lineSeparators: String(localized: "line separators")
            }
        }
    }

    /// Each look-alike, its kind and what it becomes; "" removes it.
    private static let plain: [Unicode.Scalar: (kind: Kind, text: String)] = {
        var table: [Unicode.Scalar: (kind: Kind, text: String)] = [:]
        func map(_ kind: Kind, _ values: [UInt32], to text: String) {
            for value in values { table[Unicode.Scalar(value)!] = (kind, text) }
        }
        map(.quotes, [0x2018, 0x2019, 0x201A, 0x201B, 0x2032], to: "'")              // ‘ ’ ‚ ‛ ′
        map(.quotes, [0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x00AB, 0x00BB], to: "\"") // “ ” „ ‟ ″ « »
        map(.dashes, [0x2010, 0x2011, 0x2012, 0x2013, 0x2212], to: "-")               // ‐ ‑ ‒ – −
        map(.dashes, [0x2014, 0x2015], to: "--")                                      // — ―, as the Mac makes `--`
        map(.ellipses, [0x2026], to: "...")
        map(.spaces, [0x00A0, 0x202F, 0x205F, 0x3000] + Array(0x2000...0x200A), to: " ")
        map(.invisible, [0x200B, 0x2060, 0xFEFF, 0x00AD], to: "")                     // zero-width, BOM, soft hyphen
        map(.lineSeparators, [0x2028, 0x2029], to: "\n")
        return table
    }()

    /// The kinds of look-alike in `code`, in a stable order; empty when it
    /// is plain.
    static func kinds(in code: String) -> [Kind] {
        var found: Set<Kind> = []
        for scalar in code.unicodeScalars {
            if let kind = plain[scalar]?.kind { found.insert(kind) }
        }
        return Kind.allCases.filter(found.contains)
    }

    /// `code` with every look-alike made plain: straight quotes, `-` and
    /// `--`, `...`, ordinary spaces and newlines, no invisible characters.
    static func fixed(_ code: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            if let plain = plain[scalar] {
                out.append(contentsOf: plain.text.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
