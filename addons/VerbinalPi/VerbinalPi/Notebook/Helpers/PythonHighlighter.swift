// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
#if os(macOS)
import AppKit
#endif

/// Token from Python syntax analysis.
struct PythonToken {
    let range: NSRange
    let kind: Kind

    enum Kind {
        case keyword, string, comment, number, builtIn, decorator

        #if os(macOS)
        var color: NSColor {
            switch self {
            case .keyword:   return .systemPurple
            case .string:    return .systemGreen
            case .comment:   return .secondaryLabelColor
            case .number:    return .systemBlue
            case .builtIn:   return .systemTeal
            case .decorator: return .systemOrange
            }
        }
        #endif
    }
}

/// Regex-based Python syntax tokenizer. Priority order: comments > strings > decorators > keywords > builtins > numbers.
enum PythonHighlighter {

    private static let rules: [(pattern: NSRegularExpression, kind: PythonToken.Kind)] = {
        func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        return [
            (rx(#"#[^\n]*"#), .comment),
            (rx(#"\"\"\"[\s\S]*?\"\"\"|\'\'\'[\s\S]*?\'\'\'"#), .string),
            (rx(#"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'"#), .string),
            (rx(#"@\w+"#), .decorator),
            (rx(#"\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#), .keyword),
            (rx(#"\b(?:abs|all|any|bin|bool|bytes|callable|chr|dict|dir|divmod|enumerate|eval|exec|filter|float|format|frozenset|getattr|globals|hasattr|hash|help|hex|id|input|int|isinstance|issubclass|iter|len|list|locals|map|max|min|next|object|oct|open|ord|pow|print|property|range|repr|reversed|round|set|setattr|slice|sorted|staticmethod|str|sum|super|tuple|type|vars|zip)\b"#), .builtIn),
            (rx(#"\b0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?[jJ]?\b"#), .number),
        ]
    }()

    /// Extract all tokens from Python source code. Higher-priority tokens shadow lower ones.
    static func tokens(in source: String) -> [PythonToken] {
        let full = NSRange(location: 0, length: (source as NSString).length)
        var covered = IndexSet()
        var result: [PythonToken] = []

        for (regex, kind) in rules {
            for match in regex.matches(in: source, range: full) {
                let r = match.range
                let intRange = r.location..<(r.location + r.length)
                if !covered.intersects(integersIn: intRange) {
                    result.append(PythonToken(range: r, kind: kind))
                    covered.insert(integersIn: intRange)
                }
            }
        }

        return result
    }
}
