// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Cube-aware FITS reading, ported from the v-cube web viewer (src/fits/parser.ts).
// Pixel decoding is delegated to `FITSParser.decodeSamples` so cubes and 2D
// images decode through one path.

import Foundation

/// Streaming FITS reader for spectral cubes: parses the HDU table over a
/// `CubeDataSource` (local mmap or remote range reads alike), finds cube HDUs,
/// extracts individual channel planes, and reads WAVE-TAB lookup columns.
public enum FITSCube {
    static let blockSize = 2880
    static let cardSize = 80

    /// Parse the HDU table (headers + data geometry) by streaming 2880-byte
    /// blocks from `source`. Does not read pixel data.
    public static func parseStructure(source: CubeDataSource, maxHDUs: Int = 64) async throws -> [FITSHDUnit] {
        var hdus: [FITSHDUnit] = []
        var offset = 0
        var index = 0

        while index < maxHDUs, offset + blockSize <= source.size {
            var header = FITSHeader()
            var ended = false
            var sawAnyCard = false

            while !ended {
                guard offset + blockSize <= source.size else {
                    throw FITSError.invalidFile("Truncated header in HDU \(index)")
                }
                let block = try await source.read(offset: offset, length: blockSize)
                guard block.count >= blockSize else {
                    throw FITSError.invalidFile("Short header block in HDU \(index)")
                }
                offset += blockSize

                // A leading all-blank block where an HDU should start is trailing
                // padding, not a header — stop cleanly.
                if !sawAnyCard, let first = asciiCard(block, 0),
                   first.prefix(8).trimmingCharacters(in: .whitespaces).isEmpty {
                    return hdus
                }

                for c in stride(from: 0, to: blockSize, by: cardSize) {
                    guard let card = asciiCard(block, c) else { continue }
                    let keyword = card.prefix(8).trimmingCharacters(in: .whitespaces)
                    if keyword == "END" { ended = true; break }
                    if keyword.isEmpty { continue }
                    header.add(FITSParser.parseCard(card))
                    sawAnyCard = true
                }
            }

            let dataOffset = offset
            let dataBytes = dataLength(of: header)
            let wcs = FITSWCSTransform.fromHeader(header)
            hdus.append(FITSHDUnit(id: index, header: header, dataOffset: dataOffset, dataLength: dataBytes, wcs: wcs))

            let dataBlocks = (dataBytes + blockSize - 1) / blockSize
            offset = dataOffset + dataBlocks * blockSize
            index += 1
        }
        return hdus
    }

    /// HDUs with at least three real (>1) axes — cube candidates. Skips tables.
    public static func findCubeHDUs(_ hdus: [FITSHDUnit]) -> [FITSHDUnit] {
        hdus.filter { hdu in
            let h = hdu.header
            if let x = h.string("XTENSION"), x.hasPrefix("BINTABLE") || x.hasPrefix("TABLE") { return false }
            guard h.naxis >= 3 else { return false }
            return h.naxis1 > 1 && h.naxis2 > 1 && h.int("NAXIS3") > 1
        }
    }

    /// Prefer a science cube (SCI/PRIMARY/DATA) when several cube HDUs exist.
    public static func preferredCube(_ cubes: [FITSHDUnit]) -> FITSHDUnit? {
        cubes.first { hdu in
            let ext = hdu.header.string("EXTNAME")?.uppercased() ?? ""
            return ext.hasPrefix("SCI") || ext.hasPrefix("PRIMARY") || ext.hasPrefix("DATA")
        } ?? cubes.first
    }

    /// Read one spatial channel plane (0-based) of a cube as Float32, with
    /// BLANK→NaN and BSCALE/BZERO applied.
    public static func extractPlane(source: CubeDataSource, hdu: FITSHDUnit, channel: Int) async throws -> [Float] {
        let h = hdu.header
        let nx = h.naxis1
        let ny = h.naxis2
        let nz = h.int("NAXIS3")
        guard channel >= 0, channel < Swift.max(nz, 1) else {
            throw FITSError.invalidFile("Channel \(channel) out of range [0, \(nz))")
        }
        let (planeElems, overflow) = nx.multipliedReportingOverflow(by: ny)
        guard !overflow, planeElems > 0 else {
            throw FITSError.invalidFile("Bad cube plane dimensions \(nx)×\(ny)")
        }
        guard planeElems <= FITSLimits.maxPixels else {
            throw FITSError.invalidFile("Cube plane too large: \(planeElems) px exceeds 500 Mpx cap")
        }
        let bytesPer = abs(h.bitpix) / 8
        let planeBytes = planeElems * bytesPer
        let offset = hdu.dataOffset + channel * planeBytes
        let slice = try await source.read(offset: offset, length: planeBytes)
        guard slice.count >= planeBytes else {
            throw FITSError.invalidFile("Truncated cube plane \(channel)")
        }
        let blank = h.contains("BLANK") ? h.int("BLANK") : nil
        return try FITSParser.decodeSamples(
            slice,
            bitpix: h.bitpix,
            count: planeElems,
            blank: blank,
            bscale: Float(h.bscale),
            bzero: Float(h.bzero)
        )
    }

    /// Minimal single-row BINTABLE column reader (floats/doubles) — enough for
    /// JWST WAVE-TAB wavelength lookup tables (one array-valued column).
    public static func readBintableColumn(source: CubeDataSource, hdu: FITSHDUnit, column: String) async throws -> [Double]? {
        let h = hdu.header
        guard let xt = h.string("XTENSION"), xt.hasPrefix("BINTABLE") else { return nil }
        let tfields = h.int("TFIELDS")
        let rowBytes = h.naxis1
        let nrows = h.naxis2
        guard nrows >= 1, tfields >= 1 else { return nil }

        // Width in bytes per element of each BINTABLE TFORM code.
        let elementBytes: [Character: Double] = [
            "L": 1, "X": 0.125, "B": 1, "I": 2, "J": 4, "K": 8,
            "A": 1, "E": 4, "D": 8, "C": 8, "M": 16, "P": 8, "Q": 16,
        ]
        var colOffset = 0
        for i in 1...tfields {
            let tform = (h.string("TFORM\(i)") ?? "").trimmingCharacters(in: .whitespaces)
            guard let (repeatCount, code) = parseTForm(tform) else { return nil }
            let width = Int((Double(repeatCount) * (elementBytes[code] ?? 1)).rounded(.up))
            let ttype = (h.string("TTYPE\(i)") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if ttype == column.lowercased() {
                guard code == "E" || code == "D" else { return nil }
                let raw = try await source.read(offset: hdu.dataOffset + colOffset, length: width)
                guard raw.count >= width else { return nil }
                var out = [Double](repeating: 0, count: repeatCount)
                out.withUnsafeMutableBufferPointer { dst in
                    raw.withUnsafeBytes { rb in
                        if code == "E" {
                            let p = rb.bindMemory(to: UInt32.self)
                            for k in 0..<repeatCount { dst[k] = Double(Float(bitPattern: p[k].bigEndian)) }
                        } else {
                            let p = rb.bindMemory(to: UInt64.self)
                            for k in 0..<repeatCount { dst[k] = Double(bitPattern: p[k].bigEndian) }
                        }
                    }
                }
                return out
            }
            colOffset += width
            if colOffset > rowBytes { return nil }
        }
        return nil
    }

    // MARK: - Helpers

    private static func asciiCard(_ block: Data, _ cardOffset: Int) -> String? {
        let start = block.startIndex + cardOffset
        let end = start + cardSize
        guard end <= block.endIndex else { return nil }
        return String(data: block[start..<end], encoding: .ascii)
    }

    /// FITS data-segment byte length: |BITPIX|/8 × GCOUNT × (PCOUNT + ΠNAXISᵢ).
    private static func dataLength(of header: FITSHeader) -> Int {
        let naxis = header.naxis
        guard naxis > 0, abs(header.bitpix) > 0 else { return 0 }
        let unit = abs(header.bitpix) / 8
        var nelem = 1
        for i in 1...naxis { nelem *= Swift.max(header.int("NAXIS\(i)", fallback: 1), 0) }
        let pcount = header.int("PCOUNT")
        let gcount = header.int("GCOUNT", fallback: 1)
        return unit * gcount * (nelem + pcount)
    }

    /// Split a TFORM like "3600E" / "1D" / "E" into (repeat, type code).
    private static func parseTForm(_ s: String) -> (Int, Character)? {
        var digits = ""
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber { digits.append(s[idx]); idx = s.index(after: idx) }
        guard idx < s.endIndex else { return nil }
        let code = s[idx]
        let repeatCount = digits.isEmpty ? 1 : (Int(digits) ?? 1)
        return (repeatCount, code)
    }
}
