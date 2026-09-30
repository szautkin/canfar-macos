// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - describe_tap_schema

/// The archive's own TAP_SCHEMA — so an agent writes ADQL from the real
/// columns instead of guessing them.
struct DescribeTapSchemaTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        var table: String?
        var search: String?
    }

    struct ColumnView: Encodable, Sendable {
        let name: String
        let datatype: String
        let description: String?
        let unit: String?
        let ucd: String?

        init(_ c: TapSchema.Column) {
            name = c.name
            datatype = c.datatype
            description = c.description.isEmpty ? nil : c.description
            unit = c.unit.isEmpty ? nil : c.unit
            ucd = c.ucd.isEmpty ? nil : c.ucd
        }
    }

    /// `columns` is nil in the listing and filled for one table or a search.
    struct TableView: Encodable, Sendable {
        let name: String
        let description: String?
        let columnCount: Int
        let columns: [ColumnView]?
    }

    struct KeyView: Encodable, Sendable {
        let fromTable: String
        let fromColumn: String
        let targetTable: String
        let targetColumn: String
        let description: String?

        init(_ k: TapSchema.Key) {
            fromTable = k.fromTable
            fromColumn = k.fromColumn
            targetTable = k.targetTable
            targetColumn = k.targetColumn
            description = k.description.isEmpty ? nil : k.description
        }
    }

    struct Output: Encodable, Sendable {
        let tables: [TableView]
        let keys: [KeyView]
        let totalTables: Int
        let truncated: Bool
    }

    static let maxMatches = 60


    let definition = AIToolDefinition.withStaticSchema(
        name: "describe_tap_schema",
        description: "Read the CADC TAP service's own schema: its tables, what each column means (units, IVOA UCDs) and the joins the service declares. Call this BEFORE writing ADQL instead of guessing column names — the usual mistakes are ObsCore spellings on a CAOM2 table and a column that lives on the other side of a join. ADQL notes: `SELECT TOP n`, not LIMIT; geometry predicates compare to 1 (`CONTAINS(...) = 1`). No arguments lists the tables and joins; `table` gives one table's columns; `search` finds columns by name, description or UCD across every table.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "table": { "type": "string", "description": "One table's full column list, e.g. caom2.Plane." },
            "search": { "type": "string", "description": "Columns whose name, description or UCD contains this." }
          },
          "additionalProperties": false
        }
        """#
    )

    let schema: @Sendable () async throws -> TapSchema

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let schema = try await schema()
        guard !schema.isEmpty else { throw ToolFailureReason.backendError("the service returned no TAP_SCHEMA tables") }

        if let name = args.table?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            guard let table = schema.table(name) else {
                throw ToolFailureReason.unknownTarget(
                    "no table '\(name)'. Tables: \(schema.tables.prefix(25).map(\.name).joined(separator: ", "))")
            }
            return Output(
                tables: [TableView(name: table.name, description: table.description.isEmpty ? nil : table.description,
                                   columnCount: table.columns.count, columns: table.columns.map(ColumnView.init))],
                keys: schema.keys(touching: table.name).map(KeyView.init),
                totalTables: schema.tables.count, truncated: false)
        }

        if let needle = args.search?.trimmingCharacters(in: .whitespaces), !needle.isEmpty {
            var total = 0
            let tables: [TableView] = schema.tables.compactMap { table in
                let hits = table.columns.filter {
                    $0.name.localizedCaseInsensitiveContains(needle) || $0.description.localizedCaseInsensitiveContains(needle)
                        || $0.ucd.localizedCaseInsensitiveContains(needle)
                }
                total += hits.count
                guard !hits.isEmpty else { return nil }
                return TableView(name: table.name, description: table.description.isEmpty ? nil : table.description,
                                 columnCount: table.columns.count, columns: hits.prefix(Self.maxMatches).map(ColumnView.init))
            }
            return Output(tables: tables, keys: [], totalTables: schema.tables.count, truncated: total > Self.maxMatches)
        }

        // The listing: tables and joins; ~400 columns left out on purpose.
        return Output(
            tables: schema.tables.map {
                TableView(name: $0.name, description: $0.description.isEmpty ? nil : $0.description,
                          columnCount: $0.columns.count, columns: nil)
            },
            keys: schema.keys.map(KeyView.init), totalTables: schema.tables.count, truncated: false)
    }
}

// MARK: - validate_adql_query

/// Check a query against the schema without spending a round trip on one
/// that cannot work — the same check the ADQL editor runs as you type.
struct ValidateADQLQueryTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let adql: String
    }

    struct ProblemView: Encodable, Sendable {
        /// The offending text, quoted back.
        let text: String
        let message: String
        let fix: String?
        let start: Int
        let end: Int
    }

    struct Output: Encodable, Sendable {
        let valid: Bool
        let schemaLoaded: Bool
        let problems: [ProblemView]
    }


    let definition = AIToolDefinition.withStaticSchema(
        name: "validate_adql_query",
        description: "Check an ADQL query against the archive's own schema WITHOUT running it — the check the ADQL editor runs as the user types: LIMIT (ADQL writes SELECT TOP n), unknown tables, columns a table does not have, and the qualifier CADC rejects as ambiguous (`Plane.obsID` when both joined tables have obsID). Each problem quotes the text and, when there is one obvious answer, what to write. `valid: true` means nothing could be shown wrong — not a promise the query is right; subqueries and functions are left alone rather than guessed at.",
        schema: #"""
        {
          "type": "object",
          "required": ["adql"],
          "properties": { "adql": { "type": "string", "minLength": 1 } },
          "additionalProperties": false
        }
        """#
    )

    let schema: @Sendable () async throws -> TapSchema

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        guard !args.adql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolFailureReason.invalidArgument("adql is required")
        }
        let schema = try? await schema()
        let problems = ADQLValidator.problems(in: args.adql, schema: schema)
        return Output(
            valid: problems.isEmpty,
            schemaLoaded: !(schema?.isEmpty ?? true),
            problems: problems.map {
                ProblemView(text: $0.text(in: args.adql), message: $0.message, fix: $0.fix,
                            start: $0.range.lowerBound, end: $0.range.upperBound)
            })
    }
}
