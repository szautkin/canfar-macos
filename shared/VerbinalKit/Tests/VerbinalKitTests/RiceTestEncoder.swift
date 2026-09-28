// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A RICE_1 encoder for tests — the cfitsio-compatible decoder's inverse,
/// one tile at a time:
///   1. The first pixel as 16 bits (big-endian, MSB first).
///   2. For each block, starting at pixel[0] (whose delta is 0): (fs + 1)
///      as a 4-bit nybble — the decoder subtracts 1 (raw 0 is an all-zeros
///      block) — then unary quotient and fs-bit remainder per pixel; at
///      fs = 14, BYTEPIX 2's high-entropy block, each folded difference raw
///      in 16 bits instead. Written continuously, no padding between blocks.
///   3. Padding to a byte at the very end.
func riceEncodeTile(_ pixels: [Int16], blockSize: Int, fs: Int) -> Data {
    precondition(fs >= 0 && fs <= 14, "fs must be 0-14 for BYTEPIX=2")

    func fold(_ delta: Int32) -> Int32 {
        if delta >= 0 { return delta * 2 }
        else { return -delta * 2 - 1 }
    }

    // Accumulate all bits, then pack into bytes at the end
    var bits: [UInt8] = []

    func writeBits(_ value: Int, count: Int) {
        for b in stride(from: count - 1, through: 0, by: -1) {
            bits.append(UInt8((value >> b) & 1))
        }
    }

    // First pixel: 16 bits into bit stream (big-endian)
    let firstU = UInt16(bitPattern: pixels[0])
    writeBits(Int(firstU), count: 16)

    // The decoder reads the literal into `prev`, then ALL pixelCount pixels
    // come from block iterations — including pixel[0] (whose delta = 0).
    var prev = Int32(pixels[0])
    var i = 0
    while i < pixels.count {
        let blockCount = min(blockSize, pixels.count - i)

        // Write (fs + 1) as 4-bit nybble so decoder recovers fs after subtracting 1.
        writeBits(fs + 1, count: 4)

        // Rice codes for each pixel in the block (no padding between blocks)
        for pi in 0..<blockCount {
            let delta = Int32(pixels[i + pi]) - prev
            let folded = fold(delta)
            let q = Int(folded) >> fs
            let r = Int(folded) & ((1 << fs) - 1)

            if fs == 14 {
                // High-entropy: the folded difference itself, 16 bits.
                writeBits(Int(folded) & 0xFFFF, count: 16)
            } else {
                // Unary code: q zeros then a 1, then fs remainder bits, MSB first
                for _ in 0..<q { bits.append(0) }
                bits.append(1)
                if fs > 0 {
                    writeBits(r, count: fs)
                }
            }

            prev = Int32(pixels[i + pi])
        }
        i += blockCount
    }

    // Pad to byte boundary at the very end
    while bits.count % 8 != 0 { bits.append(0) }

    // Pack bits into bytes
    var out = Data()
    var j = 0
    while j < bits.count {
        var byte: UInt8 = 0
        for b in 0..<8 {
            byte |= bits[j + b] << (7 - b)
        }
        out.append(byte)
        j += 8
    }
    return out
}
