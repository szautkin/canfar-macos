// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
#if os(macOS)
import AppKit
#endif

/// Parses ANSI escape codes in text (error tracebacks) into an attributed string.
enum AnsiColorParser {

    #if os(macOS)
    private static let standardColors: [NSColor] = [
        .black, .systemRed, .systemGreen, .systemYellow,
        .systemBlue, .systemPurple, .systemTeal, .white,
    ]

    /// Parse ANSI escape codes and return a colored NSAttributedString.
    static func parse(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var currentColor: NSColor = .labelColor
        var isBold = false

        let pattern = try! NSRegularExpression(pattern: #"\x1b\[([0-9;]*)m"#)
        let nsText = text as NSString
        var lastEnd = 0

        for match in pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            // Append text before this escape
            if match.range.location > lastEnd {
                let segment = nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: currentColor,
                    .font: isBold ? NSFont.monospacedSystemFont(ofSize: 12, weight: .bold) : defaultFont,
                ]
                result.append(NSAttributedString(string: segment, attributes: attrs))
            }
            lastEnd = match.range.location + match.range.length

            // Parse codes
            let codesStr = nsText.substring(with: match.range(at: 1))
            for codeStr in codesStr.split(separator: ";") {
                guard let code = Int(codeStr) else { continue }
                switch code {
                case 0:
                    currentColor = .labelColor
                    isBold = false
                case 1:
                    isBold = true
                case 30...37:
                    currentColor = standardColors[code - 30]
                case 39:
                    currentColor = .labelColor
                default:
                    break
                }
            }
        }

        // Append remaining text
        if lastEnd < nsText.length {
            let segment = nsText.substring(from: lastEnd)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: currentColor,
                .font: isBold ? NSFont.monospacedSystemFont(ofSize: 12, weight: .bold) : defaultFont,
            ]
            result.append(NSAttributedString(string: segment, attributes: attrs))
        }

        return result
    }
    #endif

    /// Strip all ANSI escape codes, returning plain text.
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x1b\[[0-9;]*m"#, with: "", options: .regularExpression)
    }
}
