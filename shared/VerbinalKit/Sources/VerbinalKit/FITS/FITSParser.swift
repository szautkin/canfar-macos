// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Accelerate

/// Stream-based FITS file parser. Block-aligned (2880 bytes per FITS spec).
public enum FITSParser {
    private static let blockSize = 2880
    private static let cardSize = 80
    private static let cardsPerBlock = blockSize / cardSize // 36

    /// Parse a FITS file into HDUs from a URL.
    public static func parse(url: URL) throws -> FITSFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(from: data, url: url)
    }

    /// Parse FITS from pre-loaded data (avoids double file load).
    public static func parse(from data: Data, url: URL? = nil) throws -> FITSFile {
        let fileURL = url ?? URL(fileURLWithPath: "/unknown.fits")
        var offset = 0
        var hdus: [FITSHDUnit] = []
        var hduIndex = 0

        while offset + blockSize <= data.count {
            // Try to parse next HDU header. Stop if we hit padding or invalid data.
            let header: FITSHeader
            let headerEndOffset: Int
            do {
                (header, headerEndOffset) = try parseHeader(data: data, from: offset)
            } catch {
                // Trailing padding or non-standard block — stop parsing, not an error
                break
            }
            let dataOffset = headerEndOffset

            // Calculate data length
            let dataLength: Int
            if header.naxis == 0 {
                dataLength = 0
            } else {
                guard header.naxis >= 1, header.naxis <= 999 else {
                    throw FITSError.invalidFile("NAXIS \(header.naxis) out of range [1, 999]")
                }
                guard abs(header.bitpix) > 0 else {
                    throw FITSError.invalidFile("BITPIX must be non-zero")
                }
                var size = abs(header.bitpix) / 8
                for i in 1...header.naxis {
                    let axisSize = header.int("NAXIS\(i)")
                    let (newSize, overflow) = size.multipliedReportingOverflow(by: axisSize)
                    guard !overflow else {
                        throw FITSError.invalidFile("NAXIS product overflow at axis \(i)")
                    }
                    size = newSize
                }
                dataLength = size
            }

            // Detect fpack-compressed extensions (ZCMPTYPE present)
            // and use ZNAXIS/ZBITPIX for the actual image dimensions
            var effectiveHeader = header
            if header.contains("ZCMPTYPE"), header.contains("ZNAXIS1") {
                // Preserve the raw binary table geometry before overwriting with image dimensions.
                // These are needed by FITSDecompressor to locate the heap and variable-length arrays.
                effectiveHeader.add(FITSCard(keyword: "_TNAXIS1", value: String(header.int("NAXIS1")), comment: "raw table bytes-per-row"))
                effectiveHeader.add(FITSCard(keyword: "_TNAXIS2", value: String(header.int("NAXIS2")), comment: "raw table row count"))
                effectiveHeader.add(FITSCard(keyword: "_PCOUNT", value: String(header.int("PCOUNT")), comment: "heap size in bytes"))
                // Replace NAXIS/BITPIX with the original (uncompressed) values
                effectiveHeader.add(FITSCard(keyword: "NAXIS", value: String(header.int("ZNAXIS")), comment: "from ZNAXIS"))
                effectiveHeader.add(FITSCard(keyword: "NAXIS1", value: String(header.int("ZNAXIS1")), comment: "from ZNAXIS1"))
                effectiveHeader.add(FITSCard(keyword: "NAXIS2", value: String(header.int("ZNAXIS2")), comment: "from ZNAXIS2"))
                effectiveHeader.add(FITSCard(keyword: "BITPIX", value: String(header.int("ZBITPIX")), comment: "from ZBITPIX"))
                // Mark as compressed — extractPixels will need to handle this
                effectiveHeader.add(FITSCard(keyword: "_COMPRESSED", value: "T", comment: "fpack compressed"))
            }

            let wcs = FITSWCSTransform.fromHeader(effectiveHeader)

            hdus.append(FITSHDUnit(
                id: hduIndex,
                header: effectiveHeader,
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

    /// Parse header cards until END keyword. No artificial limit on header size.
    /// Tolerates trailing padding blocks that lack a valid FITS keyword.
    private static func parseHeader(data: Data, from start: Int) throws -> (FITSHeader, Int) {
        var header = FITSHeader()
        var offset = start

        while offset + blockSize <= data.count {
            // Check first card of this block — if it's all spaces/nulls, this is padding, not a header
            let firstCardData = data[offset..<(offset + cardSize)]
            if let firstCard = String(data: firstCardData, encoding: .ascii) {
                let firstKeyword = firstCard.prefix(8).trimmingCharacters(in: .whitespaces)
                if firstKeyword.isEmpty && header.orderedCards.isEmpty {
                    // Padding block at start of a would-be HDU — not a real header
                    throw FITSError.invalidFile("No valid header (padding block)")
                }
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

        throw FITSError.invalidFile("Unexpected end of file in header (no END card found)")
    }

    /// Parse a single 80-character FITS card.
    private static func parseCard(_ cardString: String) -> FITSCard {
        let keyword = String(cardString.prefix(8)).trimmingCharacters(in: .whitespaces)

        guard cardString.count >= 10, cardString[cardString.index(cardString.startIndex, offsetBy: 8)] == "=" else {
            return FITSCard(keyword: keyword, value: String(cardString.dropFirst(8)), comment: "")
        }

        let rest = String(cardString.dropFirst(10))

        // String value: starts with '
        // FITS spec (section 4.2.1): a single quote is represented as '' (two consecutive quotes).
        if rest.trimmingCharacters(in: .whitespaces).hasPrefix("'") {
            let stripped = rest.trimmingCharacters(in: .whitespaces).dropFirst()
            var value = ""
            var idx = stripped.startIndex
            var foundEnd = false
            while idx < stripped.endIndex {
                if stripped[idx] == "'" {
                    let next = stripped.index(after: idx)
                    if next < stripped.endIndex && stripped[next] == "'" {
                        // Escaped single quote — include one literal ' and skip both chars
                        value.append("'")
                        idx = stripped.index(after: next)
                    } else {
                        // Real closing quote
                        foundEnd = true
                        idx = next
                        break
                    }
                } else {
                    value.append(stripped[idx])
                    idx = stripped.index(after: idx)
                }
            }
            if foundEnd {
                let afterQuote = stripped[idx...]
                let comment: String
                if let slashIdx = afterQuote.firstIndex(of: "/") {
                    comment = String(afterQuote[afterQuote.index(after: slashIdx)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    comment = ""
                }
                // Strip trailing spaces from value per FITS spec
                return FITSCard(keyword: keyword, value: value.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression), comment: comment)
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
    public static func extractPixels(from data: Data, hdu: FITSHDUnit) throws -> [Float] {
        let header = hdu.header

        // fpack-compressed: delegate to the Rice decompressor
        if header.contains("_COMPRESSED") {
            return try FITSDecompressor.decompress(from: data, hdu: hdu)
        }

        let (count, countOverflow) = header.naxis1.multipliedReportingOverflow(by: header.naxis2)
        guard !countOverflow else {
            throw FITSError.invalidFile("Image dimensions overflow: \(header.naxis1) × \(header.naxis2)")
        }
        guard count > 0 else { throw FITSError.invalidFile("Empty image") }
        guard count <= FITSLimits.maxPixels else {
            throw FITSError.invalidFile("Image too large: \(count) pixels exceeds 500 Mpx cap")
        }

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

    /// Compute auto-cut using median + sigma clipping (matches DS9/SAOImage behavior).
    /// Falls back to tighter percentiles (1%/99%) if sigma clipping produces a degenerate range.
    public static func autoCut(pixels: [Float], lowPercentile: Float = 0.01, highPercentile: Float = 0.99) -> (min: Float, max: Float) {
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
        // Safe min/max from the sorted, non-empty samples — avoids
        // `samples.first!`/`.last!` so a future refactor of the guard above
        // can't turn this into a crash.
        guard let minSample = samples.first, let maxSample = samples.last else {
            return (0, 1)
        }

        // Compute median
        let median = samples[samples.count / 2]

        // Compute MAD (median absolute deviation) for robust sigma estimate
        var deviations = samples.map { abs($0 - median) }
        deviations.sort()
        let mad = deviations[deviations.count / 2]
        let sigma = mad * 1.4826 // MAD to sigma conversion factor

        if sigma > 0 {
            // Use median ± 3*sigma for initial cut, then clamp to data range
            let lo = max(minSample, median - 3 * sigma)
            let hi = min(maxSample, median + 3 * sigma)
            if hi > lo { return (lo, hi) }
        }

        // Fallback: percentile-based cuts
        let lowIdx = Int(Float(samples.count - 1) * lowPercentile)
        let highIdx = Int(Float(samples.count - 1) * highPercentile)
        let lo = samples[lowIdx]
        let hi = samples[highIdx]
        return lo < hi ? (lo, hi) : (minSample, maxSample)
    }
}
