// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Lightweight HTML → plain text converter for notebook outputs.
/// Handles tables, basic formatting. NOT a full HTML parser.
enum SimpleHtmlRenderer {

    /// Convert HTML to displayable plain text with formatting hints.
    static func render(_ html: String) -> String {
        var text = html

        // Decode entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")

        // Convert line breaks
        text = text.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</tr>", with: "\n", options: .caseInsensitive)

        // Table cells → tab-separated
        text = text.replacingOccurrences(of: #"</t[dh]>\s*<t[dh][^>]*>"#, with: "\t", options: .regularExpression)

        // Strip all remaining tags
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        // Clean up excessive whitespace
        text = text.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if text contains HTML tags.
    static func containsHTML(_ text: String) -> Bool {
        text.range(of: #"<[a-zA-Z][^>]*>"#, options: .regularExpression) != nil
    }
}
