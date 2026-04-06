// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Accelerate

/// Stream-based FITS file parser. Block-aligned (2880 bytes per FITS spec).
enum FITSParser {
    private static let blockSize = 2880
    private static let cardSize = 80
    private static let cardsPerBlock = blockSize / cardSize // 36

    /// Parse a FITS file into HDUs from a URL.
    static func parse(url: URL) throws -> FITSFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(from: data, url: url)
    }

    /// Parse FITS from pre-loaded data (avoids double file load).
    static func parse(from data: Data, url: URL? = nil) throws -> FITSFile {
        let fileURL = url ?? URL(fileURLWithPath: "/unknown.fits")
        let _ = fileURL // used below
        var offset = 0
        var hdus: [FITSHDUnit] = []
        var hduIndex = 0

        while offset < data.count {
            // Parse header
            let (header, headerEndOffset) = try parseHeader(data: data, from: offset)
            let dataOffset = headerEndOffset

            // Calculate data length
            let dataLength: Int
            if header.naxis == 0 {
                dataLength = 0
            } else {
                var size = abs(header.bitpix) / 8
                for i in 1...header.naxis {
                    size *= header.int("NAXIS\(i)")
                }
                dataLength = size
            }

            let wcs = FITSWCSTransform.fromHeader(header)

            hdus.append(FITSHDUnit(
                id: hduIndex,
                header: header,
                dataOffset: dataOffset,
                dataLength: dataLength,
                wcs: wcs
            ))

            // Advance to next 2880-byte boundary
            let totalDataBlocks = (dataLength + blockSize - 1) / blockSize
            offset = dataOffset + totalDataBlocks * blockSize
            hduIndex += 1
        }

        return FITSFile(url: fileURL, hdus: hdus)
    }

    /// Parse header cards until END keyword.
    private static func parseHeader(data: Data, from start: Int) throws -> (FITSHeader, Int) {
        var header = FITSHeader()
        var offset = start
        let maxBlocks = 1000

        for _ in 0..<maxBlocks {
            guard offset + blockSize <= data.count else {
                throw FITSError.invalidFile("Unexpected end of file in header")
            }

            for cardIdx in 0..<cardsPerBlock {
                let cardStart = offset + cardIdx * cardSize
                guard cardStart + cardSize <= data.count else { break }

                let cardData = data[cardStart..<(cardStart + cardSize)]
                guard let cardString = String(data: cardData, encoding: .ascii) else { continue }

                let keyword = String(cardString.prefix(8)).trimmingCharacters(in: .whitespaces)

                if keyword == "END" {
                    let headerEndOffset = offset + blockSize // next block boundary
                    return (header, headerEndOffset)
                }

                let card = parseCard(cardString)
                header.add(card)
            }

            offset += blockSize
        }

        throw FITSError.invalidFile("Header too large (>1000 blocks)")
    }

    /// Parse a single 80-character FITS card.
    private static func parseCard(_ cardString: String) -> FITSCard {
        let keyword = String(cardString.prefix(8)).trimmingCharacters(in: .whitespaces)

        guard cardString.count >= 10, cardString[cardString.index(cardString.startIndex, offsetBy: 8)] == "=" else {
            return FITSCard(keyword: keyword, value: String(cardString.dropFirst(8)), comment: "")
        }

        let rest = String(cardString.dropFirst(10))

        // String value: starts with '
        if rest.trimmingCharacters(in: .whitespaces).hasPrefix("'") {
            let stripped = rest.trimmingCharacters(in: .whitespaces).dropFirst()
            if let endQuote = stripped.firstIndex(of: "'") {
                let value = String(stripped[stripped.startIndex..<endQuote])
                let afterQuote = stripped[stripped.index(after: endQuote)...]
                let comment: String
                if let slashIdx = afterQuote.firstIndex(of: "/") {
                    comment = String(afterQuote[afterQuote.index(after: slashIdx)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    comment = ""
                }
                return FITSCard(keyword: keyword, value: value, comment: comment)
            }
        }

        // Numeric/boolean value: split by /
        let parts = rest.split(separator: "/", maxSplits: 1)
        let value = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let comment = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return FITSCard(keyword: keyword, value: value, comment: comment)
    }

    // MARK: - Pixel Data Extraction

    /// Extract pixel data from a FITS HDU as Float32 array with BSCALE/BZERO applied.
    static func extractPixels(from data: Data, hdu: FITSHDUnit) throws -> [Float] {
        let header = hdu.header
        let count = header.naxis1 * header.naxis2
        guard count > 0 else { throw FITSError.invalidFile("Empty image") }

        let bytesPerPixel = abs(header.bitpix) / 8
        let expectedBytes = count * bytesPerPixel
        guard hdu.dataLength >= expectedBytes else {
            throw FITSError.invalidFile("Truncated data: expected \(expectedBytes) bytes, got \(hdu.dataLength)")
        }
        guard hdu.dataOffset + hdu.dataLength <= data.count else {
            throw FITSError.invalidFile("Data segment extends beyond file")
        }

        let dataSlice = data[hdu.dataOffset..<(hdu.dataOffset + hdu.dataLength)]
        let bscale = Float(header.bscale)
        let bzero = Float(header.bzero)

        var pixels: [Float]

        switch header.bitpix {
        case 8:
            pixels = dataSlice.map { Float($0) }

        case 16:
            pixels = [Float](repeating: 0, count: count)
            dataSlice.withUnsafeBytes { raw in
                let int16Ptr = raw.bindMemory(to: UInt16.self)
                for i in 0..<count {
                    let bigEndian = int16Ptr[i]
                    pixels[i] = Float(Int16(bitPattern: bigEndian.bigEndian))
                }
            }

        case 32:
            pixels = [Float](repeating: 0, count: count)
            dataSlice.withUnsafeBytes { raw in
                let int32Ptr = raw.bindMemory(to: UInt32.self)
                for i in 0..<count {
                    pixels[i] = Float(Int32(bitPattern: int32Ptr[i].bigEndian))
                }
            }

        case -32: // IEEE 754 float, big-endian
            pixels = [Float](repeating: 0, count: count)
            dataSlice.withUnsafeBytes { raw in
                let uint32Ptr = raw.bindMemory(to: UInt32.self)
                for i in 0..<count {
                    pixels[i] = Float(bitPattern: uint32Ptr[i].bigEndian)
                }
            }

        case -64: // IEEE 754 double, big-endian
            pixels = [Float](repeating: 0, count: count)
            dataSlice.withUnsafeBytes { raw in
                let uint64Ptr = raw.bindMemory(to: UInt64.self)
                for i in 0..<count {
                    pixels[i] = Float(Double(bitPattern: uint64Ptr[i].bigEndian))
                }
            }

        default:
            throw FITSError.unsupportedBitpix(header.bitpix)
        }

        // Apply BSCALE/BZERO: physical = bzero + bscale * raw
        if bscale != 1.0 || bzero != 0.0 {
            var scale = bscale
            var zero = bzero
            var result = [Float](repeating: 0, count: count)
            vDSP_vsmsa(pixels, 1, &scale, &zero, &result, 1, vDSP_Length(count))
            pixels = result
        }

        return pixels
    }

    /// Compute auto-cut percentiles from pixel data.
    static func autoCut(pixels: [Float], lowPercentile: Float = 0.005, highPercentile: Float = 0.995) -> (min: Float, max: Float) {
        // Sample up to 100K pixels
        let maxSamples = 100_000
        let step = max(1, pixels.count / maxSamples)
        var samples: [Float] = []
        samples.reserveCapacity(min(pixels.count, maxSamples))

        for i in Swift.stride(from: 0, to: pixels.count, by: step) {
            let v = pixels[i]
            if v.isFinite { samples.append(v) }
        }

        guard !samples.isEmpty else { return (0, 1) }
        samples.sort()

        let lowIdx = Int(Float(samples.count - 1) * lowPercentile)
        let highIdx = Int(Float(samples.count - 1) * highPercentile)
        return (samples[lowIdx], samples[highIdx])
    }
}
