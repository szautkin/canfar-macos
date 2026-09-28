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
public enum FITSDecompressor {

    // MARK: Errors

    public enum Error: LocalizedError {
        case unsupportedCompression(String)
        case malformedDescriptor(row: Int)
        case truncatedHeap(row: Int, needed: Int, available: Int)
        case unsupportedBitpix(Int)
        case decodingFailed(row: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedCompression(let type):
                return "Unsupported FITS compression type: \(type). Only RICE_1 is supported."
            case .malformedDescriptor(let row):
                return "Malformed variable-length array descriptor in binary table row \(row)."
            case .truncatedHeap(let row, let needed, let available):
                return "Compressed tile \(row): need \(needed) bytes but heap has \(available)."
            case .unsupportedBitpix(let bp):
                return "This fpack image has ZBITPIX=\(bp); RICE_1 integer images of 8, 16 and 32 bits can be read, quantised floating point cannot yet."
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
    public static func decompress(from data: Data, hdu: FITSHDUnit) throws -> [Float] {
        let h = hdu.header
        let stored = try storedValues(from: data, hdu: hdu)
        // For fpack-compressed files the BSCALE/BZERO in the binary-table header
        // apply to the *original* integer values (not the compressed form).
        // BZERO=32768 is standard for unsigned-uint16 stored as int16 in FITS.
        let bscale = Float(h.double("BSCALE", fallback: 1.0))
        let bzero  = Float(h.double("BZERO",  fallback: 0.0))
        var floatPixels = stored.map { Float($0) }
        if bscale != 1.0 || bzero != 0.0 {
            var scale = bscale
            var zero  = bzero
            var result = [Float](repeating: 0, count: floatPixels.count)
            vDSP_vsmsa(floatPixels, 1, &scale, &zero, &result, 1, vDSP_Length(floatPixels.count))
            floatPixels = result
        }
        return floatPixels
    }

    /// The image's stored integer values, row-major — of the whole image, or
    /// of `box` only, decoding just the tiles it touches (a small cutout of
    /// a large fpack tile reads a few rows, not the file).
    public static func storedValues(from data: Data, hdu: FITSHDUnit, box: PixelBox? = nil) throws -> [Int32] {
        let h = hdu.header

        // Validate compression type
        let zcmptype = h.string("ZCMPTYPE") ?? ""
        guard zcmptype == "RICE_1" else {
            throw Error.unsupportedCompression(zcmptype.isEmpty ? "(none)" : zcmptype)
        }

        // Integer images of 8, 16 or 32 bits; quantised floating point is not read yet.
        let zbitpix = h.int("ZBITPIX")
        guard [8, 16, 32].contains(zbitpix) else {
            throw Error.unsupportedBitpix(zbitpix)
        }
        // BYTEPIX when the file names it, else the image's own width.
        let bytePix = h.string("ZNAME2")?.uppercased() == "BYTEPIX" ? h.int("ZVAL2", fallback: zbitpix / 8) : zbitpix / 8

        // Original image dimensions (these are now stored as NAXIS1/NAXIS2 in the header)
        let imageWidth  = h.int("NAXIS1")   // e.g. 2048
        let imageHeight = h.int("NAXIS2")   // e.g. 2048
        let area = box ?? PixelBox(x0: 0, y0: 0, x1: imageWidth, y1: imageHeight)

        // Tile dimensions from ZTILE keywords (ZTILE1=width, ZTILE2=height per tile)
        let tileWidth  = h.int("ZTILE1", fallback: imageWidth)
        let tileHeight = h.int("ZTILE2", fallback: 1)
        guard tileWidth > 0, tileHeight > 0 else { throw FITSError.invalidFile("Compressed FITS: tiles of no size") }

        // Rice parameters
        let blockSize = h.int("ZVAL1", fallback: 32)  // pixels per Rice block

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

        // Pixel count of what is returned
        let (totalPixels, totalPixelsOverflow) = area.width.multipliedReportingOverflow(by: area.height)
        guard !totalPixelsOverflow else {
            throw FITSError.invalidFile("Compressed FITS: image dimensions overflow (\(area.width)×\(area.height))")
        }
        if let refusal = FITSMemoryBudget.refusal(width: area.width, height: area.height) {
            throw FITSError.invalidFile(refusal)
        }
        var stored = [Int32](repeating: 0, count: totalPixels)

        // Number of tiles along each axis
        let nTilesX = (imageWidth  + tileWidth  - 1) / tileWidth
        let nTilesY = (imageHeight + tileHeight - 1) / tileHeight
        let nTiles  = nTilesX * nTilesY

        // Some non-standard fpack files may have a descriptor/tile count mismatch;
        // process only the tiles that exist in both axes.
        let tilesToDecode = min(nTiles, tableNRows)

        for tileIdx in 0..<tilesToDecode {
            // Where the tile is; tiles the area does not touch are not decoded.
            let tileCol = tileIdx % nTilesX
            let tileRow = tileIdx / nTilesX
            let tileX0 = tileCol * tileWidth, tileY0 = tileRow * tileHeight
            let tilePxWidth  = max(0, min(tileWidth,  imageWidth  - tileX0))
            let tilePxHeight = max(0, min(tileHeight, imageHeight - tileY0))
            guard tilePxWidth > 0, tilePxHeight > 0,
                  tileX0 < area.x1, tileX0 + tilePxWidth > area.x0,
                  tileY0 < area.y1, tileY0 + tilePxHeight > area.y0 else { continue }

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
            guard nelem <= FITSLimits.maxTileBytes else {
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
            let tilePxCount  = tilePxWidth * tilePxHeight

            let decoded: [Int32]
            do {
                decoded = try RiceDecoder.decode(
                    bytes: tileBytes,
                    pixelCount: tilePxCount,
                    blockSize: blockSize,
                    bytePix: bytePix
                )
            } catch let riceError as RiceDecoder.Error {
                throw Error.decodingFailed(row: tileIdx, message: "\(riceError.description) (tilePxCount=\(tilePxCount), tileBytes=\(tileBytes.count), blockSize=\(blockSize))")
            }

            // Copy the tile's pixels that fall in the area to their place in it
            for py in max(0, area.y0 - tileY0)..<min(tilePxHeight, area.y1 - tileY0) {
                let srcBase = py * tilePxWidth
                let destBase = (tileY0 + py - area.y0) * area.width
                for px in max(0, area.x0 - tileX0)..<min(tilePxWidth, area.x1 - tileX0) where srcBase + px < decoded.count {
                    stored[destBase + tileX0 + px - area.x0] = decoded[srcBase + px]
                }
            }
        }
        return stored
    }
}

// MARK: - Rice Decoder

/// cfitsio's Rice parameters for one pixel width (`fits_rdecomp`,
/// `_short`, `_byte`): how many bits name a block's `fs`, which `fs` means
/// the block is stored raw, and how wide a raw value is.
struct RiceParameters: Equatable {
    let bytePix: Int
    let fsBits: Int
    /// A block whose `fs` is this is high-entropy: its differences are
    /// stored raw, `bBits` each, with no Rice code.
    let fsMax: Int
    var bBits: Int { bytePix * 8 }

    init?(bytePix: Int) {
        switch bytePix {
        case 1: (fsBits, fsMax) = (3, 6)
        case 2: (fsBits, fsMax) = (4, 14)
        case 4: (fsBits, fsMax) = (5, 25)
        default: return nil
        }
        self.bytePix = bytePix
    }
}

/// The FITS RICE_1 decoder, as cfitsio's `fits_rdecomp` family decodes
/// (Pence et al. 2010, A&A 524, A51):
/// - the first value of a tile is stored literally, `bytePix` bytes big-endian;
/// - the rest are differences, in blocks of `blockSize`, each block led by
///   its `fs` (`fsBits` bits, stored plus one): below zero, every difference
///   is zero; at `fsMax`, each is stored raw in `bBits` bits; otherwise each
///   is a unary quotient and an `fs`-bit remainder;
/// - a difference is folded (0, −1, 1, −2, … as 0, 1, 2, 3, …), and values
///   wrap at the pixel width.
enum RiceDecoder {

    enum Error: Swift.Error {
        case bufferUnderrun
        case unsupportedWidth(Int)

        var description: String {
            switch self {
            case .bufferUnderrun: return "compressed data ended unexpectedly"
            case .unsupportedWidth(let bytes): return "no Rice decoding for \(bytes)-byte pixels"
            }
        }
    }

    /// Decodes one tile into its stored values, as signed integers of the
    /// pixel width (unsigned for 8-bit, as BITPIX 8 is).
    static func decode(bytes: Data.SubSequence, pixelCount: Int, blockSize: Int, bytePix: Int) throws -> [Int32] {
        guard pixelCount > 0 else { return [] }
        guard let rice = RiceParameters(bytePix: bytePix) else { throw Error.unsupportedWidth(bytePix) }
        let mask: UInt32 = rice.bBits == 32 ? .max : (1 << rice.bBits) - 1
        var reader = BitReader(data: bytes)
        guard var last = reader.readBits(rice.bBits) else { throw Error.bufferUnderrun }

        var output = [Int32]()
        output.reserveCapacity(pixelCount)
        func append(_ difference: UInt32) {
            // Unfold, add, and wrap at the width — unsigned, as cfitsio does.
            let delta = difference & 1 == 0 ? difference >> 1 : ~(difference >> 1)
            last = (last &+ delta) & mask
            output.append(signed(last, bytePix: bytePix))
        }

        while output.count < pixelCount {
            let blockEnd = min(output.count + blockSize, pixelCount)
            guard let stored = reader.readBits(rice.fsBits) else { throw Error.bufferUnderrun }
            let fs = Int(stored) - 1
            if fs < 0 {
                while output.count < blockEnd { output.append(signed(last, bytePix: bytePix)) }
            } else if fs == rice.fsMax {
                while output.count < blockEnd {
                    guard let raw = reader.readBits(rice.bBits) else { throw Error.bufferUnderrun }
                    append(raw)
                }
            } else {
                while output.count < blockEnd {
                    guard let quotient = reader.readUnary(), let remainder = reader.readBits(fs) else {
                        throw Error.bufferUnderrun
                    }
                    append(UInt32(truncatingIfNeeded: quotient) << fs | remainder)
                }
            }
        }
        return output
    }

    /// A stored value of the pixel width as a signed integer.
    private static func signed(_ value: UInt32, bytePix: Int) -> Int32 {
        switch bytePix {
        case 1: return Int32(value & 0xFF)
        case 2: return Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: value)))
        default: return Int32(bitPattern: value)
        }
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
}

// MARK: - Bit Reader

/// An MSB-first bit reader over a continuous stream, a word at a time.
struct BitReader {
    private let bytes: Data.SubSequence
    private var next: Data.Index
    /// Bits not yet read, left-aligned.
    private var buffer: UInt64 = 0
    private var buffered = 0

    init(data: Data.SubSequence) {
        bytes = data
        next = data.startIndex
    }

    private mutating func refill() {
        while buffered <= 56, next < bytes.endIndex {
            buffer |= UInt64(bytes[next]) << (56 - buffered)
            next += 1
            buffered += 8
        }
    }

    /// The next `n` bits (0…32), or nil if fewer remain.
    mutating func readBits(_ n: Int) -> UInt32? {
        guard n > 0 else { return 0 }
        if buffered < n { refill() }
        guard buffered >= n else { return nil }
        let value = UInt32(buffer >> (64 - n))
        buffer = n == 64 ? 0 : buffer << n
        buffered -= n
        return value
    }

    /// One bit, 0 or 1, or nil when the stream is done.
    mutating func readBit() -> UInt8? {
        readBits(1).map(UInt8.init)
    }

    /// Up to 8 bits, zero-padded when fewer remain; nil when none do.
    mutating func readByte() -> UInt8? {
        refill()
        guard buffered > 0 else { return nil }
        let take = min(8, buffered)
        guard let value = readBits(take) else { return nil }
        return UInt8(value << (8 - take))
    }

    /// The number of zeros before the next 1, which is read too; nil when
    /// the stream ends first.
    mutating func readUnary() -> Int? {
        var zeros = 0
        while true {
            refill()
            guard buffered > 0 else { return nil }
            let leading = buffer.leadingZeroBitCount
            if leading < buffered {
                zeros += leading
                buffer <<= (leading + 1)
                buffered -= leading + 1
                return zeros
            }
            zeros += buffered
            buffer = 0
            buffered = 0
        }
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
