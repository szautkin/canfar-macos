// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Accelerate

// MARK: - Public API

/// Decompresses fpack (Rice/RICE_1) compressed FITS image extensions.
///
/// fpack stores compressed image tiles in a FITS binary table extension.
/// Each table row contains a variable-length byte array with one Rice-compressed
/// image tile. This type reads the binary table heap, extracts per-tile compressed
/// bytes, and decodes them using the Rice adaptive entropy coding algorithm.
enum FITSDecompressor {

    // MARK: Errors

    enum Error: LocalizedError {
        case unsupportedCompression(String)
        case malformedDescriptor(row: Int)
        case truncatedHeap(row: Int, needed: Int, available: Int)
        case unsupportedBitpix(Int)
        case decodingFailed(row: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedCompression(let type):
                return "Unsupported FITS compression type: \(type). Only RICE_1 is supported."
            case .malformedDescriptor(let row):
                return "Malformed variable-length array descriptor in binary table row \(row)."
            case .truncatedHeap(let row, let needed, let available):
                return "Compressed tile \(row): need \(needed) bytes but heap has \(available)."
            case .unsupportedBitpix(let bp):
                return "RICE_1 decompressor does not support ZBITPIX=\(bp). Only 16 is currently implemented."
            case .decodingFailed(let row, let message):
                return "Rice decode failed for tile \(row): \(message)"
            }
        }
    }

    // MARK: Entry Point

    /// Decompress a RICE_1 compressed image HDU to a Float32 pixel array.
    ///
    /// - Parameters:
    ///   - data: Full FITS file data (memory-mapped is fine).
    ///   - hdu:  The compressed-image HDU. Its header must contain `_COMPRESSED`,
    ///           `_TNAXIS1`, `_TNAXIS2`, `_PCOUNT`, and all ZNAXIS/ZTILE/ZVAL keywords.
    /// - Returns: Decompressed pixels as Float32, in row-major order, BSCALE/BZERO applied.
    /// - Throws:  `FITSDecompressor.Error` or `FITSError` on malformed data.
    static func decompress(from data: Data, hdu: FITSHDUnit) throws -> [Float] {
        let h = hdu.header

        // Validate compression type
        let zcmptype = h.string("ZCMPTYPE") ?? ""
        guard zcmptype == "RICE_1" else {
            throw Error.unsupportedCompression(zcmptype.isEmpty ? "(none)" : zcmptype)
        }

        // Only ZBITPIX=16 is currently implemented
        let zbitpix = h.int("ZBITPIX")
        guard zbitpix == 16 else {
            throw Error.unsupportedBitpix(zbitpix)
        }

        // Original image dimensions (these are now stored as NAXIS1/NAXIS2 in the header)
        let imageWidth  = h.int("NAXIS1")   // e.g. 2048
        let imageHeight = h.int("NAXIS2")   // e.g. 2048

        // Tile dimensions from ZTILE keywords (ZTILE1=width, ZTILE2=height per tile)
        let tileWidth  = h.int("ZTILE1", fallback: imageWidth)
        let tileHeight = h.int("ZTILE2", fallback: 1)

        // Rice parameters
        let blockSize = h.int("ZVAL1", fallback: 32)  // pixels per Rice block
        // ZVAL2 is BYTEPIX but we validate via ZBITPIX above

        // Raw binary table geometry (stashed by parser before NAXIS1/2 were overwritten)
        let tableRowBytes = h.int("_TNAXIS1")  // bytes per row in the main table (e.g. 8)
        let tableNRows    = h.int("_TNAXIS2")  // number of rows = number of tiles
        let pcount        = h.int("_PCOUNT")   // heap size in bytes

        // Heap starts immediately after the main table data
        let tableStart = hdu.dataOffset
        let (tableBytes, tableBytesOverflow) = tableRowBytes.multipliedReportingOverflow(by: tableNRows)
        guard !tableBytesOverflow else {
            throw FITSError.invalidFile("Compressed FITS: table size overflow (tableRowBytes=\(tableRowBytes), tableNRows=\(tableNRows))")
        }
        let heapStart = tableStart + tableBytes

        guard pcount >= 0, heapStart <= data.count - pcount else {
            throw FITSError.invalidFile(
                "Compressed FITS: heap extends beyond file (heapStart=\(heapStart), pcount=\(pcount), fileSize=\(data.count))"
            )
        }

        // Total pixel count in the uncompressed image
        let (totalPixels, totalPixelsOverflow) = imageWidth.multipliedReportingOverflow(by: imageHeight)
        guard !totalPixelsOverflow else {
            throw FITSError.invalidFile("Compressed FITS: image dimensions overflow (\(imageWidth)×\(imageHeight))")
        }
        guard totalPixels <= FITSViewerConstants.maxPixels else {
            throw FITSError.invalidFile("Compressed FITS: image too large (\(totalPixels) pixels exceeds 500 Mpx cap)")
        }
        var rawPixels = [Int32](repeating: 0, count: totalPixels)

        // Number of tiles along each axis
        let nTilesX = (imageWidth  + tileWidth  - 1) / tileWidth
        let nTilesY = (imageHeight + tileHeight - 1) / tileHeight
        let nTiles  = nTilesX * nTilesY

        // Some non-standard fpack files may have a descriptor/tile count mismatch;
        // process only the tiles that exist in both axes.
        let tilesToDecode = min(nTiles, tableNRows)

        for tileIdx in 0..<tilesToDecode {
            // Parse variable-length array descriptor from the main table.
            // Each row is `tableRowBytes` bytes wide; the first 8 bytes encode
            // the descriptor: (nelem: Int32, offset: Int32), both big-endian.
            let rowStart = tableStart + tileIdx * tableRowBytes
            guard rowStart + 8 <= data.count else {
                throw Error.malformedDescriptor(row: tileIdx)
            }

            guard let nelemRaw = data.readBigEndianInt32(at: rowStart),
                  let offsetRaw = data.readBigEndianInt32(at: rowStart + 4) else {
                throw Error.malformedDescriptor(row: tileIdx)
            }
            let nelem  = Int(nelemRaw)
            let offset = Int(offsetRaw)

            guard nelem >= 0, offset >= 0 else {
                throw Error.malformedDescriptor(row: tileIdx)
            }
            guard nelem <= FITSViewerConstants.maxTileBytes else {
                throw Error.decodingFailed(row: tileIdx, message: "nelem \(nelem) exceeds 64 MB per tile cap")
            }

            let tileDataStart = heapStart + offset
            guard nelem <= pcount, tileDataStart <= data.count - nelem,
                  tileDataStart <= heapStart + pcount - nelem else {
                throw Error.truncatedHeap(row: tileIdx, needed: nelem,
                                          available: heapStart + pcount - tileDataStart)
            }

            // Compressed bytes for this tile
            let tileBytes = data[tileDataStart..<(tileDataStart + nelem)]

            // Actual pixel dimensions of this tile (edge tiles may be smaller)
            let tileCol = tileIdx % nTilesX
            let tileRow = tileIdx / nTilesX
            let tilePxWidth  = max(0, min(tileWidth,  imageWidth  - tileCol * tileWidth))
            let tilePxHeight = max(0, min(tileHeight, imageHeight - tileRow * tileHeight))
            guard tilePxWidth > 0, tilePxHeight > 0 else { continue }
            let tilePxCount  = tilePxWidth * tilePxHeight

            // Decode Rice-compressed bytes into signed 16-bit integers
            let decoded: [Int16]
            do {
                decoded = try RiceDecoder.decode(
                    bytes: tileBytes,
                    pixelCount: tilePxCount,
                    blockSize: blockSize
                )
            } catch let riceError as RiceDecoder.Error {
                throw Error.decodingFailed(row: tileIdx, message: "\(riceError.description) (tilePxCount=\(tilePxCount), tileBytes=\(tileBytes.count), blockSize=\(blockSize))")
            }

            // Copy decoded pixels into the output buffer at the correct image position
            let destRowStart = tileRow * tileHeight
            for py in 0..<tilePxHeight {
                let srcBase  = py * tilePxWidth
                let destBase = (destRowStart + py) * imageWidth + tileCol * tileWidth
                for px in 0..<tilePxWidth {
                    guard destBase + px < rawPixels.count else { continue }
                    rawPixels[destBase + px] = Int32(decoded[srcBase + px])
                }
            }
        }

        // Convert raw Int32 values to Float32, applying BSCALE/BZERO.
        // For fpack-compressed files the BSCALE/BZERO in the binary-table header
        // apply to the *original* integer values (not the compressed form).
        // BZERO=32768 is standard for unsigned-uint16 stored as int16 in FITS.
        let bscale = Float(h.double("BSCALE", fallback: 1.0))
        let bzero  = Float(h.double("BZERO",  fallback: 0.0))

        var floatPixels = rawPixels.map { Float($0) }

        if bscale != 1.0 || bzero != 0.0 {
            var scale = bscale
            var zero  = bzero
            var result = [Float](repeating: 0, count: totalPixels)
            vDSP_vsmsa(floatPixels, 1, &scale, &zero, &result, 1, vDSP_Length(totalPixels))
            floatPixels = result
        }

        return floatPixels
    }
}

// MARK: - Rice Decoder

/// Pure-Swift implementation of the FITS RICE_1 decompression algorithm.
///
/// This matches the cfitsio `fits_rdecomp` function for BYTEPIX=2 (16-bit pixels).
///
/// Algorithm overview (Pence et al. 2010, A&A 524, A51):
/// - The first pixel of each tile is stored literally (big-endian int16).
/// - Remaining pixels are delta-coded then Rice-entropy-coded in blocks of `blockSize`.
/// - Within each block: one byte encodes the "fs" (fundamental sequence) parameter,
///   followed by unary-coded quotients and `fs`-bit remainders for each pixel.
/// - The signed delta is unfolded from an unsigned value using the fold mapping:
///   0→0, 1→-1, 2→1, 3→-2, 4→2, …
enum RiceDecoder {

    enum Error: Swift.Error {
        case bufferUnderrun
        case badFsValue(Int)

        var description: String {
            switch self {
            case .bufferUnderrun: return "compressed data ended unexpectedly"
            case .badFsValue(let fs): return "invalid fs=\(fs) in block header"
            }
        }
    }

    // Constants matching cfitsio for BYTEPIX=2
    private static let bytepix = 2
    // Maximum encodable value for BYTEPIX=2: 2^15 - 1
    private static let valueMax: Int32 = 32767
    private static let valueMin: Int32 = -32768

    /// Decode a Rice-compressed tile.
    ///
    /// - Parameters:
    ///   - bytes:      Compressed byte sequence for this tile.
    ///   - pixelCount: Number of pixels expected in the output.
    ///   - blockSize:  Rice block size (ZVAL1, typically 32).
    /// - Returns:      Decoded signed 16-bit pixel values (as Int16).
    static func decode(bytes: Data.SubSequence, pixelCount: Int, blockSize: Int) throws -> [Int16] {
        guard pixelCount > 0 else { return [] }

        var reader = BitReader(data: bytes)
        var output = [Int16]()
        output.reserveCapacity(pixelCount)

        // The first 2 bytes encode the literal first pixel value (big-endian int16).
        // cfitsio loads this into lastpix but does NOT output it separately —
        // the first block iteration outputs pixel[0].
        guard let firstHigh = reader.readByte(), let firstLow = reader.readByte() else {
            throw Error.bufferUnderrun
        }
        var prev = Int32(Int16(bitPattern: (UInt16(firstHigh) << 8) | UInt16(firstLow)))

        var pixelsRemaining = pixelCount
        while pixelsRemaining > 0 {
            let blockCount = min(blockSize, pixelsRemaining)

            // Read fs nybble (4 bits) then SUBTRACT 1 (cfitsio: fs = raw - 1).
            //   raw=0 → fs=-1 → all diffs zero (no bits consumed)
            //   raw=1 → fs=0  → unary-only mode
            //   raw=2..15 → fs=1..14 → fs remainder bits per pixel
            guard let fsRaw = reader.readBits(4) else {
                for _ in 0..<pixelsRemaining {
                    output.append(Int16(truncatingIfNeeded: prev))
                }
                break
            }
            let fs = Int(fsRaw) - 1  // cfitsio: fs = (b >> nbits) - 1

            if fs < 0 {
                // All diffs zero — fill block with lastpix (no bits consumed)
                for _ in 0..<blockCount {
                    output.append(Int16(truncatingIfNeeded: prev))
                }
            } else {
                // General case: unary quotient + fs-bit remainder
                let fsMask = Int32((1 << fs) - 1)
                for _ in 0..<blockCount {
                    var q: Int32 = 0
                    var exhausted = false
                    while true {
                        guard let bit = reader.readBit() else {
                            exhausted = true
                            break
                        }
                        if bit == 1 { break }
                        q += 1
                    }
                    if exhausted {
                        // Stream exhausted mid-block: remaining pixels = prev (delta=0)
                        output.append(Int16(truncatingIfNeeded: prev))
                        continue
                    }
                    var r: Int32 = 0
                    for _ in 0..<fs {
                        guard let bit = reader.readBit() else {
                            // Partial remainder — treat as zero
                            break
                        }
                        r = (r << 1) | Int32(bit)
                    }
                    let delta = (q << fs) | (r & fsMask)
                    let signedDelta = unfold(delta)
                    prev = Int32(Int16(truncatingIfNeeded: prev + signedDelta))
                    output.append(Int16(truncatingIfNeeded: prev))
                }
            }

            pixelsRemaining -= blockCount
        }

        return output
    }

    // MARK: - Fold/Unfold Mapping

    /// Unfold unsigned Rice-coded delta to signed integer.
    ///
    /// The fold mapping (Golomb/Rice): 0→0, 1→−1, 2→1, 3→−2, 4→2, …
    /// Inverse: even n → n/2, odd n → −(n+1)/2
    @inline(__always)
    static func unfold(_ n: Int32) -> Int32 {
        if n & 1 == 0 {
            return n >> 1          // even: positive
        } else {
            return -((n + 1) >> 1) // odd: negative
        }
    }

    /// Clamp to signed 16-bit range to prevent overflow.
    @inline(__always)
    private static func clamp(_ v: Int32) -> Int32 {
        min(max(v, valueMin), valueMax)
    }
}

// MARK: - Bit Reader

/// A streaming MSB-first bit reader. Tracks a simple bit position into the data.
/// No buffering — reads bits directly. Matches cfitsio's continuous bit stream.
struct BitReader {
    private let bytes: [UInt8]
    private var bitPos: Int = 0
    private let totalBits: Int

    init(data: Data.SubSequence) {
        self.bytes = Array(data)
        self.totalBits = bytes.count * 8
    }

    /// Read exactly N bits from the stream. Returns nil if not enough bits remain.
    mutating func readBits(_ n: Int) -> UInt32? {
        guard bitPos + n <= totalBits else { return nil }
        var result: UInt32 = 0
        for _ in 0..<n {
            let byteIdx = bitPos >> 3
            let bitIdx = 7 - (bitPos & 7)
            result = (result << 1) | UInt32((bytes[byteIdx] >> bitIdx) & 1)
            bitPos += 1
        }
        return result
    }

    /// Read a single bit. Returns 0 or 1, or nil if exhausted.
    mutating func readBit() -> UInt8? {
        guard bitPos < totalBits else { return nil }
        let byteIdx = bitPos >> 3
        let bitIdx = 7 - (bitPos & 7)
        let bit = (bytes[byteIdx] >> bitIdx) & 1
        bitPos += 1
        return bit
    }

    /// Read up to 8 bits from the continuous bit stream, zero-padding if fewer remain.
    ///
    /// Returns nil only if the stream is fully exhausted (zero bits remain).
    /// If 1-7 bits remain, they are returned in the high bits, zero-padded in the low bits.
    mutating func readByte() -> UInt8? {
        guard bitPos < totalBits else { return nil }
        let available = min(8, totalBits - bitPos)
        var result: UInt32 = 0
        for _ in 0..<available {
            let byteIdx = bitPos >> 3
            let bitIdx = 7 - (bitPos & 7)
            result = (result << 1) | UInt32((bytes[byteIdx] >> bitIdx) & 1)
            bitPos += 1
        }
        // Zero-pad low bits if fewer than 8 bits were available
        result <<= (8 - available)
        return UInt8(result)
    }
}

// MARK: - Data Extension

private extension Data {
    /// Read a big-endian Int32 from `offset` (absolute byte index in self).
    /// Returns nil if there are fewer than 4 bytes available at `offset`.
    func readBigEndianInt32(at offset: Int) -> Int32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let b0 = Int32(self[offset])
        let b1 = Int32(self[offset + 1])
        let b2 = Int32(self[offset + 2])
        let b3 = Int32(self[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
