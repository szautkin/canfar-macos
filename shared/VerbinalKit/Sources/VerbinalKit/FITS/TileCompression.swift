// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The tiled image compression convention (FITS 4.0 §10, what fpack
/// writes): an image kept as a binary table, one compressed tile per row.
///
/// The one place that knows which of the table's cards describe the image,
/// what they are called there, and where the tiles are — for the parser
/// (the header readers see), the decompressor (the tiles) and the local
/// cutter (the header it writes back), so the three cannot disagree.
public enum TileCompression {

    /// Where the tiles are and how they were compressed, read once from the table's header.
    public struct Layout: Sendable, Equatable {
        /// ZCMPTYPE: RICE_1, GZIP_1, HCOMPRESS_1, …
        public let algorithm: String
        /// ZBITPIX: the image's own BITPIX.
        public let bitpix: Int
        public let tileWidth: Int
        public let tileHeight: Int
        /// Rice's pixels per block (the BLOCKSIZE parameter), 32 by default.
        public let blockSize: Int
        /// Bytes per pixel as compressed (the BYTEPIX parameter), the image's width by default.
        public let bytePix: Int
        /// The table's shape: bytes per row, rows (one per tile), and the heap after it.
        public let rowBytes: Int
        public let rows: Int
        public let heapBytes: Int

        /// The layout of a compressed image's table; nil for any other header.
        public init?(table: FITSHeader) {
            guard table.contains("ZCMPTYPE"), table.contains("ZNAXIS1") else { return nil }
            algorithm = table.string("ZCMPTYPE") ?? ""
            bitpix = table.int("ZBITPIX")
            let width = table.int("ZNAXIS1")
            tileWidth = table.int("ZTILE1", fallback: width)
            tileHeight = table.int("ZTILE2", fallback: 1)
            // Compression parameters are named: ZNAMEn = 'BLOCKSIZE', ZVALn = 32.
            var parameters: [String: Int] = [:]
            for index in 1...9 {
                guard let name = table.string("ZNAME\(index)")?.uppercased() else { break }
                parameters[name] = table.int("ZVAL\(index)")
            }
            blockSize = parameters["BLOCKSIZE"] ?? 32
            bytePix = parameters["BYTEPIX"] ?? max(1, abs(bitpix) / 8)
            rowBytes = table.int("NAXIS1")
            rows = table.int("NAXIS2")
            heapBytes = max(0, table.int("PCOUNT"))
        }
    }

    /// What becomes of one of the table's cards in the image it holds.
    public enum Fate: Equatable, Sendable {
        case keep
        case drop
        case rename(String)
    }

    /// The table's structure and the convention's own keywords are dropped
    /// (the image's shape is rebuilt from the Z-keywords); ZBLANK is the
    /// image's BLANK; checksums, which vouched for the table, go; every
    /// other card — EXTNAME, WCS, BZERO, OBJECT, a keyword such as ZD —
    /// is the image's as written.
    public static func fate(of keyword: String) -> Fate {
        switch keyword {
        case "ZBLANK":
            return .rename("BLANK")
        case "XTENSION", "SIMPLE", "BITPIX", "NAXIS", "PCOUNT", "GCOUNT", "EXTEND", "TFIELDS", "THEAP", "END",
             "CHECKSUM", "DATASUM", "ZIMAGE", "ZCMPTYPE", "ZBITPIX", "ZNAXIS", "ZMASKCMP", "ZQUANTIZ", "ZDITHER0",
             "ZSIMPLE", "ZTENSION", "ZEXTEND", "ZBLOCKED", "ZPCOUNT", "ZGCOUNT", "ZHECKSUM", "ZDATASUM":
            return .drop
        default:
            let numbered = ["NAXIS", "ZNAXIS", "ZTILE", "ZNAME", "ZVAL",
                            "TTYPE", "TFORM", "TUNIT", "TDIM", "TNULL", "TSCAL", "TZERO", "TDISP"]
            let isNumbered = numbered.contains { prefix in
                keyword.count > prefix.count && keyword.hasPrefix(prefix) && keyword.dropFirst(prefix.count).allSatisfy(\.isNumber)
            }
            return isNumbered ? .drop : .keep
        }
    }

    /// The image's structural cards, from the table's Z-keywords, in the
    /// order a header opens with.
    public static func structure(fromTable table: FITSHeader) -> [(keyword: String, value: String)] {
        let axes = table.int("ZNAXIS")
        var cards: [(keyword: String, value: String)] = [("XTENSION", "'IMAGE   '"), ("BITPIX", "\(table.int("ZBITPIX"))"),
                                                          ("NAXIS", "\(axes)")]
        if axes > 0 { cards += (1...axes).map { ("NAXIS\($0)", "\(table.int("ZNAXIS\($0)"))") } }
        return cards + [("PCOUNT", "0"), ("GCOUNT", "1")]
    }

    /// The image's header, as cfitsio presents a compressed image: its
    /// structure, then the table's other cards in order, each by its fate.
    public static func imageHeader(fromTable table: FITSHeader) -> FITSHeader {
        var header = FITSHeader()
        for (keyword, value) in structure(fromTable: table) {
            header.add(FITSCard(keyword: keyword, value: value, comment: ""))
        }
        for card in table.orderedCards {
            switch fate(of: card.keyword) {
            case .keep: header.add(card)
            case .rename(let name): header.add(FITSCard(keyword: name, value: card.value, comment: card.comment))
            case .drop: break
            }
        }
        return header
    }
}
