// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A binary table's layout (FITS 4.0 §7.3) — its columns, each with its
/// name, unit, type and how many values a row holds — and a numeric
/// column's values read from the table's rows. What a spectrum is read
/// from: an HST `_x1d` (an array per row), a JWST `x1d` or an SDSS coadd
/// (a number per row).
public struct FITSBinaryTable: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public let name: String
        public let unit: String?
        /// The TFORM type code: L X B I J K A E D C M P Q.
        public let type: Character
        /// How many values each row holds.
        public let count: Int
        /// Where the column starts in a row, in bytes.
        public let offset: Int
        public let scale: Double
        public let zero: Double
        public let null: Int64?

        /// A column of real or integer numbers, one or more per row.
        public var isNumeric: Bool { "BIJKED".contains(type) && count > 0 }

        /// Bytes a row gives the column.
        public var width: Int { FITSBinaryTable.width(type: type, count: count) }

        /// "FLUX [erg/s/cm**2/Angstrom]".
        public var description: String { unit.map { "\(name) [\($0)]" } ?? name }
    }

    public let columns: [Column]
    public let rowBytes: Int
    public let rows: Int

    /// The layout a BINTABLE header gives; nil for any other HDU, or one
    /// whose columns do not fit its rows.
    public init?(header: FITSHeader) {
        guard header.string("XTENSION")?.hasPrefix("BINTABLE") == true else { return nil }
        let fields = header.int("TFIELDS")
        var columns: [Column] = []
        var offset = 0
        for index in stride(from: 1, through: fields, by: 1) {
            guard let (count, type) = Self.parse(tform: header.string("TFORM\(index)") ?? "") else { return nil }
            let unit = header.string("TUNIT\(index)").flatMap { $0.isEmpty ? nil : $0 }
            let null = header.contains("TNULL\(index)") ? Int64(header.int("TNULL\(index)")) : nil
            columns.append(Column(name: header.string("TTYPE\(index)") ?? "COL\(index)", unit: unit, type: type,
                                  count: count, offset: offset,
                                  scale: header.double("TSCAL\(index)", fallback: 1),
                                  zero: header.double("TZERO\(index)", fallback: 0), null: null))
            offset += Self.width(type: type, count: count)
        }
        guard offset <= header.naxis1 else { return nil }
        self.columns = columns
        rowBytes = header.naxis1
        rows = header.naxis2
    }

    /// The column called `name`, whatever its case.
    public func column(named name: String) -> Column? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Each row's values of a numeric column, scaled by TSCAL and TZERO, an
    /// integer column's TNULL as NaN; nil for a column that holds no numbers.
    /// `data` starts at the table's first row.
    public func values(of column: Column, in data: Data) -> [[Double]]? {
        guard column.isNumeric, data.count >= rows * rowBytes else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<rows).map { row in Self.values(of: column, in: raw, at: row * rowBytes) }
        }
    }

    /// One row's values of a numeric column; `row` is that row's bytes.
    public func values(of column: Column, inRow row: Data) -> [Double]? {
        guard column.isNumeric, row.count >= column.offset + column.width else { return nil }
        return row.withUnsafeBytes { Self.values(of: column, in: $0, at: 0) }
    }

    private static func values(of column: Column, in raw: UnsafeRawBufferPointer, at rowStart: Int) -> [Double] {
        let size = width(type: column.type, count: 1)
        return (0..<column.count).map { index in
            let (value, isNull) = number(raw, at: rowStart + column.offset + index * size, type: column.type, null: column.null)
            return isNull ? .nan : column.zero + column.scale * value
        }
    }

    // MARK: - The format

    /// A TFORM such as `1024E`, `D` or `1PE(1024)`: how many, and of what.
    static func parse(tform: String) -> (count: Int, type: Character)? {
        let text = tform.trimmingCharacters(in: .whitespaces)
        let digits = text.prefix { $0.isNumber }
        guard let type = text.dropFirst(digits.count).first, "LXBIJKAEDCMPQ".contains(type) else { return nil }
        return (digits.isEmpty ? 1 : Int(digits) ?? 1, type)
    }

    /// Bytes `count` values of `type` take: bits packed for X, a descriptor for P and Q.
    static func width(type: Character, count: Int) -> Int {
        switch type {
        case "X": return (count + 7) / 8
        case "L", "B", "A": return count
        case "I": return 2 * count
        case "J", "E": return 4 * count
        case "K", "D", "C", "P": return 8 * count
        case "M", "Q": return 16 * count
        default: return 0
        }
    }

    private static func number(_ raw: UnsafeRawBufferPointer, at offset: Int, type: Character, null: Int64?) -> (Double, Bool) {
        func big<T: FixedWidthInteger>(_: T.Type) -> T { T(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        let integer: Int64
        switch type {
        case "B": integer = Int64(raw[offset])
        case "I": integer = Int64(big(Int16.self))
        case "J": integer = Int64(big(Int32.self))
        case "K": integer = big(Int64.self)
        case "E": return (Double(Float(bitPattern: big(UInt32.self))), false)
        case "D": return (Double(bitPattern: big(UInt64.self)), false)
        default: return (.nan, true)
        }
        return (Double(integer), integer == null)
    }
}
