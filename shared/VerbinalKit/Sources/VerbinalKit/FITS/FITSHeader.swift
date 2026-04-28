// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A single FITS header card (keyword = value / comment).
public struct FITSCard: Sendable {
    public let keyword: String
    public let value: String
    public let comment: String

    public init(keyword: String, value: String, comment: String) {
        self.keyword = keyword
        self.value = value
        self.comment = comment
    }
}

/// Parsed FITS header with typed accessors.
public struct FITSHeader: Sendable {
    private var cards: [String: FITSCard] = [:]
    public private(set) var orderedCards: [FITSCard] = []

    public init() {}

    public mutating func add(_ card: FITSCard) {
        cards[card.keyword] = card
        orderedCards.append(card)
    }

    public func string(_ key: String) -> String? {
        guard let card = cards[key] else { return nil }
        return card.value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'")).trimmingCharacters(in: .whitespaces)
    }

    public func int(_ key: String, fallback: Int = 0) -> Int {
        guard let card = cards[key], let v = Int(card.value.trimmingCharacters(in: .whitespaces)) else { return fallback }
        return v
    }

    public func double(_ key: String, fallback: Double = 0.0) -> Double {
        guard let card = cards[key], let v = Double(card.value.trimmingCharacters(in: .whitespaces)) else { return fallback }
        return v
    }

    public func bool(_ key: String, fallback: Bool = false) -> Bool {
        guard let card = cards[key] else { return fallback }
        return card.value.trimmingCharacters(in: .whitespaces) == "T"
    }

    public func contains(_ key: String) -> Bool { cards[key] != nil }

    // Standard image keywords
    public var bitpix: Int { int("BITPIX") }
    public var naxis: Int { int("NAXIS") }
    public var naxis1: Int { int("NAXIS1") }
    public var naxis2: Int { int("NAXIS2") }
    public var bscale: Double { double("BSCALE", fallback: 1.0) }
    public var bzero: Double { double("BZERO", fallback: 0.0) }
}
