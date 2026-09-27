// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One thing wrong with a query, and where.
struct ADQLProblem: Sendable, Equatable {
    /// Character offsets of the offending text.
    let range: Range<Int>
    let message: String
    /// What to write instead, when there is one obvious answer.
    let fix: String?

    /// The words on the editor's list and in an agent's refusal — one place.
    var summary: String { fix.map { "\(message) — write \($0)" } ?? message }

    func text(in adql: String) -> String {
        let characters = Array(adql)
        let upper = min(range.upperBound, characters.count)
        guard range.lowerBound < upper else { return "" }
        return String(characters[range.lowerBound..<upper])
    }
}

/// Catches the ADQL mistakes CADC would reject, before the round trip.
///
/// Not a parser, deliberately: a parser that is 95 % right refuses good
/// queries, and a false positive here disables Execute on a query that
/// would have worked. It reads what FROM/JOIN name and every
/// `qualifier.column`, and reports only what it is sure of — anything it
/// cannot resolve (a subquery, a function, a table not in the schema's
/// view) is left alone. String literals and comments are blanked first, so
/// `'o.obsID'` in a literal is never read as a column.
///
/// Rules: `LIMIT` (ADQL writes `SELECT TOP n`); a table the service does
/// not have; a column a table does not have; and a bare table name used as
/// a qualifier for a column two joined tables share — CADC answers
/// "Column [obsID] is ambiguous" (`caom2.Plane.obsID` or an alias is fine).
enum ADQLValidator {

    /// Everything this is sure is wrong, in order. Empty means "nothing
    /// this can be sure about", not "valid". Without a schema only the
    /// dialect rules apply.
    static func problems(in adql: String, schema: TapSchema?) -> [ADQLProblem] {
        let tokens = tokenize(masked(adql))
        var problems = dialectProblems(tokens)
        guard let schema, !schema.isEmpty else { return problems }

        let from = fromEntries(tokens)
        let unknownTables = from.compactMap { entry -> ADQLProblem? in
            guard schema.table(entry.written) == nil else { return nil }
            return ADQLProblem(range: entry.range, message: "no table \"\(entry.written)\" in this service",
                               fix: nearest(entry.written, in: schema.tables.map(\.name)))
        }
        // Columns of a table that does not exist are noise.
        guard unknownTables.isEmpty else { return problems + unknownTables }

        for reference in tokens where reference.parts.count >= 2 && !from.contains(where: { $0.range == reference.range }) {
            let qualifier = reference.parts.dropLast().joined(separator: ".")
            let column = reference.parts.last!
            let table: String
            if let aliased = from.first(where: { $0.alias.map { same($0, qualifier) } ?? false }) {
                table = aliased.written
            } else if let full = from.first(where: { same($0.written, qualifier) }) {
                table = full.written
            } else if let bare = from.first(where: { same($0.bare, qualifier) }) {
                let owners = from.filter { schema.table($0.written)?.column(column) != nil }.map(\.written)
                if owners.count > 1 {
                    problems.append(ADQLProblem(
                        range: reference.range,
                        message: "\(qualifier).\(column) is ambiguous — \(column) is in \(owners.joined(separator: " and "))",
                        fix: "\(bare.written).\(column)"))
                    continue
                }
                table = bare.written
            } else {
                continue   // not an alias or a table here: a function, a subquery, or unknowable
            }
            guard let resolved = schema.table(table), resolved.column(column) == nil else { continue }
            problems.append(ADQLProblem(
                range: reference.range, message: "\(table) has no column \"\(column)\"",
                fix: nearest(column, in: resolved.columns.map(\.name)).map { "\(qualifier).\($0)" }))
        }
        return problems.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: - Rules

    /// `LIMIT n` — ADQL writes `SELECT TOP n` (CADC rejects LIMIT).
    private static func dialectProblems(_ tokens: [Token]) -> [ADQLProblem] {
        tokens.indices.compactMap { i in
            guard same(tokens[i].text, "limit"), i + 1 < tokens.count, Int(tokens[i + 1].text) != nil else { return nil }
            return ADQLProblem(range: tokens[i].range.lowerBound..<tokens[i + 1].range.upperBound,
                               message: "ADQL has no LIMIT", fix: "SELECT TOP \(tokens[i + 1].text)")
        }
    }

    /// The closest known name, when exactly one is close: another case, a
    /// prefix, or the schema-qualified form of a bare name. Not an edit
    /// distance — a wrong "did you mean" is worse than none.
    private static func nearest(_ given: String, in known: [String]) -> String? {
        let lower = given.lowercased()
        let hits = Set(known.filter { name in
            let candidate = name.lowercased()
            let bare = candidate.split(separator: ".").last.map(String.init) ?? candidate
            return candidate == lower || candidate.hasPrefix(lower) || lower.hasPrefix(candidate) || bare == lower
        })
        return hits.count == 1 ? hits.first : nil
    }

    // MARK: - Reading the text

    private struct Token {
        let text: String
        let range: Range<Int>
        /// A dotted identifier's parts; one part for a plain word.
        var parts: [String] { text.split(separator: ".", omittingEmptySubsequences: false).map(String.init) }
        var isIdentifier: Bool { text.first.map { $0.isLetter || $0 == "_" } ?? false }
    }

    private struct FromEntry {
        let written: String
        let range: Range<Int>
        let alias: String?
        var bare: String { written.split(separator: ".").last.map(String.init) ?? written }
    }

    private static let clauseWords: Set<String> = [
        "where", "on", "group", "order", "having", "limit", "using", "select", "join", "inner", "left",
        "right", "outer", "full", "cross", "natural", "union", "as", "top", "offset", "and", "or",
    ]

    /// Tables after FROM (and its commas) and each JOIN, with their aliases.
    private static func fromEntries(_ tokens: [Token]) -> [FromEntry] {
        var entries: [FromEntry] = []
        var i = 0
        while i < tokens.count {
            let word = tokens[i].text.lowercased()
            guard word == "from" || word == "join" else { i += 1; continue }
            repeat {
                i += 1
                guard i < tokens.count, tokens[i].isIdentifier, !clauseWords.contains(tokens[i].text.lowercased()) else { break }
                let table = tokens[i]
                var alias: String?
                if i + 1 < tokens.count, same(tokens[i + 1].text, "as"), i + 2 < tokens.count {
                    alias = tokens[i + 2].text
                    i += 2
                } else if i + 1 < tokens.count, tokens[i + 1].isIdentifier,
                          !clauseWords.contains(tokens[i + 1].text.lowercased()) {
                    alias = tokens[i + 1].text
                    i += 1
                }
                entries.append(FromEntry(written: table.text, range: table.range, alias: alias))
                i += 1
            } while word == "from" && i < tokens.count && tokens[i].text == ","
        }
        return entries
    }

    /// Dotted identifiers and numbers as tokens; every other non-space
    /// character is a token of its own.
    private static func tokenize(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        while i < characters.count {
            let c = characters[i]
            if c.isWhitespace { i += 1; continue }
            let start = i
            if isWord(c) {
                while i < characters.count,
                      isWord(characters[i]) || (characters[i] == "." && i + 1 < characters.count && isWord(characters[i + 1])
                                                 && characters[start].isLetter) {
                    i += 1
                }
            } else {
                i += 1
            }
            tokens.append(Token(text: String(characters[start..<i]), range: start..<i))
        }
        return tokens
    }

    /// The query with string literals and comments blanked, offsets kept.
    private static func masked(_ adql: String) -> [Character] {
        var characters = Array(adql)
        var i = 0
        while i < characters.count {
            if characters[i] == "'" {
                i += 1
                while i < characters.count {
                    if characters[i] == "'" {
                        if i + 1 < characters.count, characters[i + 1] == "'" { characters[i] = " "; characters[i + 1] = " "; i += 2; continue }
                        break
                    }
                    characters[i] = " "
                    i += 1
                }
                i += 1
            } else if characters[i] == "-", i + 1 < characters.count, characters[i + 1] == "-" {
                while i < characters.count, characters[i] != "\n" { characters[i] = " "; i += 1 }
            } else if characters[i] == "/", i + 1 < characters.count, characters[i + 1] == "*" {
                while i < characters.count, !(characters[i] == "*" && i + 1 < characters.count && characters[i + 1] == "/") {
                    characters[i] = " "
                    i += 1
                }
                if i < characters.count { characters[i] = " " }
                if i + 1 < characters.count { characters[i + 1] = " " }
                i += 2
            } else {
                i += 1
            }
        }
        return characters
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }
}
