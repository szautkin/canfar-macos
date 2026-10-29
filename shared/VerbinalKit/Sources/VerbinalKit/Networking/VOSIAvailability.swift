// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a service says of itself at its VOSI `/availability`: whether it is
/// available, and its note — "service is in read-only mode". A service can
/// answer 200 and still say it is not available (plan 52 E4).
public struct VOSIAvailability: Equatable, Sendable {
    public let available: Bool
    public let note: String?

    public init(available: Bool, note: String?) {
        self.available = available
        self.note = note
    }

    /// Nil when `data` is not an availability document.
    public init?(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        guard let available = Self.element("available", in: text) else { return nil }
        self.available = available.lowercased() == "true"
        self.note = Self.element("note", in: text)
    }

    /// The text of the first `<available>` or `<note>`, with or without a namespace prefix.
    private static func element(_ name: String, in text: String) -> String? {
        let pattern = "<(?:[A-Za-z_][\\w.-]*:)?\(name)(?:\\s[^>]*)?>(.*?)</(?:[A-Za-z_][\\w.-]*:)?\(name)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
