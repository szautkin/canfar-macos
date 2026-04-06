// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A single FITS header card (keyword = value / comment).
struct FITSCard: Sendable {
    let keyword: String
    let value: String
    let comment: String
}

/// Parsed FITS header with typed accessors.
struct FITSHeader: Sendable {
    private var cards: [String: FITSCard] = [:]
    private(set) var orderedCards: [FITSCard] = []

    mutating func add(_ card: FITSCard) {
        cards[card.keyword] = card
        orderedCards.append(card)
    }

    func string(_ key: String) -> String? {
        guard let card = cards[key] else { return nil }
        return card.value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'")).trimmingCharacters(in: .whitespaces)
    }

    func int(_ key: String, fallback: Int = 0) -> Int {
        guard let card = cards[key], let v = Int(card.value.trimmingCharacters(in: .whitespaces)) else { return fallback }
        return v
    }

    func double(_ key: String, fallback: Double = 0.0) -> Double {
        guard let card = cards[key], let v = Double(card.value.trimmingCharacters(in: .whitespaces)) else { return fallback }
        return v
    }

    func bool(_ key: String, fallback: Bool = false) -> Bool {
        guard let card = cards[key] else { return fallback }
        return card.value.trimmingCharacters(in: .whitespaces) == "T"
    }

    func contains(_ key: String) -> Bool { cards[key] != nil }

    // Standard image keywords
    var bitpix: Int { int("BITPIX") }
    var naxis: Int { int("NAXIS") }
    var naxis1: Int { int("NAXIS1") }
    var naxis2: Int { int("NAXIS2") }
    var bscale: Double { double("BSCALE", fallback: 1.0) }
    var bzero: Double { double("BZERO", fallback: 0.0) }
}
