// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a TAP service says about itself in `TAP_SCHEMA`: its tables, what
/// each column means, and the joins it declares.
struct TapSchema: Sendable, Equatable {

    struct Column: Sendable, Equatable {
        let name: String
        let datatype: String
        let description: String
        let unit: String
        /// IVOA UCD — what the number means, whatever the column is called.
        let ucd: String
    }

    struct Table: Sendable, Equatable {
        let name: String
        let description: String
        var columns: [Column]

        func column(_ name: String) -> Column? {
            columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// A join the service itself declares.
    struct Key: Sendable, Equatable {
        let fromTable: String
        let targetTable: String
        let fromColumn: String
        let targetColumn: String
        let description: String
    }

    var tables: [Table] = []
    var keys: [Key] = []

    var isEmpty: Bool { tables.isEmpty }

    /// ADQL identifiers are case-insensitive unless quoted.
    func table(_ name: String) -> Table? {
        tables.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func keys(touching table: String) -> [Key] {
        keys.filter {
            $0.fromTable.caseInsensitiveCompare(table) == .orderedSame
                || $0.targetTable.caseInsensitiveCompare(table) == .orderedSame
        }
    }

    /// One result set of a TAP query: header names and rows of strings.
    typealias Rows = (headers: [String], rows: [[String]])

    /// Assembles the three `TAP_SCHEMA` queries into one schema. Fields are
    /// read by name (exact, then any case), so a service that orders or
    /// cases them differently — or omits one, such as `ucd` — costs that
    /// field, not the schema.
    static func build(tables: Rows, columns: Rows, keys: Rows) -> TapSchema {
        var schema = TapSchema()
        let tableField = reader(tables.headers)
        for row in tables.rows {
            schema.tables.append(Table(name: tableField(row, "table_name"),
                                       description: tableField(row, "description"), columns: []))
        }
        let columnField = reader(columns.headers)
        for row in columns.rows {
            let owner = columnField(row, "table_name")
            let column = Column(name: columnField(row, "column_name"), datatype: columnField(row, "datatype"),
                                description: columnField(row, "description"), unit: columnField(row, "unit"),
                                ucd: columnField(row, "ucd"))
            if let index = schema.tables.firstIndex(where: { $0.name == owner }) {
                schema.tables[index].columns.append(column)
            } else {
                // A column whose table was not listed still belongs somewhere.
                schema.tables.append(Table(name: owner, description: "", columns: [column]))
            }
        }
        let keyField = reader(keys.headers)
        for row in keys.rows {
            schema.keys.append(Key(fromTable: keyField(row, "from_table"), targetTable: keyField(row, "target_table"),
                                   fromColumn: keyField(row, "from_column"), targetColumn: keyField(row, "target_column"),
                                   description: keyField(row, "description")))
        }
        return schema
    }

    private static func reader(_ headers: [String]) -> ([String], String) -> String {
        let trimmed = headers.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        return { row, name in
            let index = trimmed.firstIndex(of: name)
                ?? trimmed.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
            guard let index, row.indices.contains(index) else { return "" }
            return row[index]
        }
    }
}
