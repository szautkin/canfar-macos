// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Makes sure an archive query returns what identifies each of its rows
/// (plan 54 B), so previews, details and downloads work for any query, not
/// only the form's.
///
/// A query whose rows are products and that does not already return their
/// publisher ID gains one select item, `Plane.publisherID AS "Publisher ID"`,
/// before its FROM. Nothing else in it is touched. Like ``ADQLValidator``
/// it reads, not parses: what it cannot read for sure (a UNION, a table
/// made by a subquery) is left as written.
enum ADQLIdentifier {

    /// What `ensure` found, and the query to run.
    struct Checked: Sendable, Equatable {
        /// The query as written, or with the identifier added.
        let adql: String
        /// The select item added, as written into `adql`.
        let added: String?
        /// What identifies its rows; nil when nothing does.
        let identifies: ResultIdentifier?
        /// Why its rows are not products, when they are not.
        let gap: Gap?
    }

    /// Why a query's rows have no publisher ID.
    enum Gap: Sendable, Equatable {
        /// DISTINCT, GROUP BY or an aggregate: its rows are summaries.
        case summarized
        /// Its rows are observations; `join` gives each its products.
        case observations(join: String)
        /// No table it reads has an identifier; `join`, when one can be named.
        case noIdentifier(join: String?)
        /// A UNION, or a table made by a subquery: not read, so not changed.
        case notRead

        /// English, for agents.
        var message: String {
            switch self {
            case .summarized:
                "Its rows are summaries (DISTINCT, GROUP BY or an aggregate), not products: they have no publisher ID, so no previews, details or downloads."
            case .observations(let join):
                "Its rows are observations: their details open by observation URI, but previews and downloads need a product's publisher ID. For products, add \(join)"
            case .noIdentifier(.some(let join)):
                "No table it reads has a publisher ID, so its rows have no previews, details or downloads. For products, add \(join)"
            case .noIdentifier(nil):
                "No table it reads has a publisher ID (caom2.Plane and ivoa.ObsCore have one), so its rows have no previews, details or downloads."
            case .notRead:
                "Verbinal did not check it for a publisher ID: it has a UNION or a subquery in FROM."
            }
        }

        /// The same, in the person's language.
        var localizedMessage: String {
            switch self {
            case .summarized:
                String(localized: "These rows are summaries (DISTINCT, GROUP BY or an aggregate), not products: they have no publisher ID, so no previews, details or downloads.")
            case .observations(let join):
                String(localized: "These rows are observations: their details open, but previews and downloads need a product. For products, add \(join)")
            case .noIdentifier(.some(let join)):
                String(localized: "These rows have no publisher ID, so no previews, details or downloads. For products, add \(join)")
            case .noIdentifier(nil):
                String(localized: "These rows have no publisher ID (caom2.Plane and ivoa.ObsCore have one), so no previews, details or downloads.")
            case .notRead:
                String(localized: "Verbinal did not check this query for a publisher ID: it has a UNION or a subquery in FROM.")
            }
        }

        /// The JOIN that gives each row its product, when there is one.
        var join: String? {
            switch self {
            case .observations(let join): join
            case .noIdentifier(let join): join
            case .summarized, .notRead: nil
            }
        }
    }

    /// `adql`, sure to return what identifies its rows when they have
    /// something to identify them; and, when they cannot, why.
    static func ensure(_ adql: String, schema: TapSchema?) -> Checked {
        let original = Array(adql)
        let tokens = ADQLValidator.tokenize(ADQLValidator.masked(adql))
        func unchanged(_ identifies: ResultIdentifier?, _ gap: Gap?) -> Checked {
            Checked(adql: adql, added: nil, identifies: identifies, gap: gap)
        }

        // Depth in parentheses: the query's own clauses are at 0.
        var depth = 0
        let depths = tokens.map { token -> Int in
            if token.text == ")" { depth = max(0, depth - 1) }
            defer { if token.text == "(" { depth += 1 } }
            return depth
        }
        let top = tokens.indices.filter { depths[$0] == 0 }
        func word(_ i: Int) -> String { tokens[i].text.lowercased() }
        guard let select = top.first(where: { word($0) == "select" }),
              let from = top.first(where: { $0 > select && word($0) == "from" }), from > select + 1 else {
            return unchanged(nil, nil)
        }
        if top.contains(where: { ["union", "intersect", "except"].contains(word($0)) })
            || top.contains(where: { $0 > from && tokens[$0].text == "(" && ["from", "join", ","].contains(word($0 - 1)) }) {
            return unchanged(nil, .notRead)
        }

        let entries = ADQLValidator.fromEntries(top.filter { $0 >= from && !["(", ")"].contains(tokens[$0].text) }.map { tokens[$0] })
        let archive = entries.contains { ["caom2", "ivoa"].contains($0.written.split(separator: ".").first?.lowercased() ?? "") }
        let identified = entries.compactMap { entry in
            ResultIdentifier.column(of: entry.written, schema: schema).map { (entry: entry, column: $0) }
        }
        let chosen = identified.first { $0.column.identifies == .product } ?? identified.first
        guard let chosen else {
            return unchanged(nil, archive ? .noIdentifier(join: entries.lazy.compactMap(planeJoin).first) : nil)
        }

        let items = selectItems(tokens, depths: depths, from: select + 1, to: from)
        let distinct = word(select + 1) == "distinct"
        let aggregate = ((select + 1)..<from).contains { i in
            aggregates.contains(word(i)) && i + 1 < from && tokens[i + 1].text == "("
        }
        let grouped = top.contains { i in
            guard i > from else { return false }
            return word(i) == "having" || (word(i) == "group" && i + 1 < tokens.count && word(i + 1) == "by")
        }
        if distinct || aggregate || grouped { return unchanged(nil, .summarized) }

        let identifies = chosen.column.identifies
        let gap: Gap? = identifies == .observation ? planeJoin(chosen.entry).map { .observations(join: $0) } : nil
        let names = Set([chosen.entry.written, chosen.entry.bare, chosen.entry.alias].compactMap { $0?.lowercased() })
        let selected = items.contains { item in
            let texts = item.map { tokens[$0].text }
            if texts == ["*"] { return true }
            if texts.count == 3, texts[1] == ".", texts[2] == "*" { return names.contains(texts[0].lowercased()) }
            return outputName(of: item, tokens: tokens, original: original).flatMap(ResultIdentifier.of(header:)) == identifies
        }
        if selected { return unchanged(identifies, gap) }

        let qualifier = chosen.entry.alias ?? chosen.entry.written
        guard qualifier.first.map({ $0.isLetter || $0 == "_" }) ?? false, let last = items.last?.last else {
            return unchanged(nil, .notRead)
        }
        let added = "\(qualifier).\(chosen.column.name) AS \"\(identifies.header)\""
        let at = tokens[last].range.upperBound
        let rewritten = String(original[..<at]) + ", " + added + String(original[at...])
        return Checked(adql: rewritten, added: added, identifies: identifies, gap: gap)
    }

    /// `adql` with `join` after its FROM clause's tables: before its own
    /// WHERE, GROUP BY, HAVING or ORDER BY, else at its end. The editor's
    /// **Join Plane** (plan 54 E1).
    static func joining(_ join: String, into adql: String) -> String {
        let original = Array(adql)
        let tokens = ADQLValidator.tokenize(ADQLValidator.masked(adql))
        var depth = 0
        var from: Int?
        for (i, token) in tokens.enumerated() {
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth -= 1 }
            guard depth == 0 else { continue }
            let word = token.text.lowercased()
            if from == nil {
                if word == "from" { from = i }
            } else if ["where", "group", "having", "order"].contains(word) {
                let at = token.range.lowerBound
                return String(original[..<at]) + join + "\n" + String(original[at...])
            }
        }
        let trimmed = adql.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return trimmed + "\n" + join
    }

    private static let aggregates: Set<String> = ["count", "sum", "avg", "min", "max"]

    /// The JOIN that gives a row of `entry` its product, for the archive's
    /// tables that have one.
    private static func planeJoin(_ entry: ADQLValidator.FromEntry) -> String? {
        let keys = ["caom2.observation": "obsID", "caom2.artifact": "planeID"]
        guard let key = keys[entry.written.lowercased()] else { return nil }
        return "JOIN caom2.Plane AS Plane ON Plane.\(key) = \(entry.alias ?? entry.written).\(key)"
    }

    /// The select list's items, as token indices, split at its own commas.
    /// TOP n and ALL are not items; DISTINCT starts the first.
    private static func selectItems(_ tokens: [ADQLValidator.Token], depths: [Int],
                                    from start: Int, to end: Int) -> [[Int]] {
        var i = start
        if i < end, ADQLValidator.same(tokens[i].text, "all") { i += 1 }
        if i + 1 < end, ADQLValidator.same(tokens[i].text, "top") { i += 2 }
        var items: [[Int]] = [[]]
        for j in i..<max(i, end) {
            if tokens[j].text == ",", depths[j] == 0 { items.append([]) } else { items[items.count - 1].append(j) }
        }
        return items.filter { !$0.isEmpty }
    }

    /// The header an item gives its column: after AS, a name after the
    /// expression, or a column's own name. Quoted names are read from the
    /// query as written (the tokens have them blanked).
    private static func outputName(of item: [Int], tokens: [ADQLValidator.Token], original: [Character]) -> String? {
        let texts = item.map { tokens[$0].text }
        func quoted(endingAt k: Int) -> String? {
            guard k >= 1, texts[k] == "\"", texts[k - 1] == "\"" else { return nil }
            return String(original[tokens[item[k - 1]].range.upperBound..<tokens[item[k]].range.lowerBound])
        }
        guard let last = texts.indices.last else { return nil }
        if let name = quoted(endingAt: last) { return name }
        guard tokens[item[last]].isIdentifier else { return nil }
        // `col`, `t.col`, `expr AS name`, or `expr name`.
        if texts.count == 1 { return tokens[item[last]].parts.last }
        return texts[last - 1] == "." ? nil : texts[last]
    }
}
