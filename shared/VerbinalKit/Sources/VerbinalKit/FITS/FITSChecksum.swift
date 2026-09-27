// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The FITS checksum convention (Seaman, Pence & Rots): a 32-bit ones'
/// complement sum of the big-endian words of an HDU. DATASUM is the data's
/// sum; CHECKSUM encodes the complement of the whole HDU's, so an intact
/// HDU sums to −0 (all ones).
public enum FITSChecksum {

    /// The ones' complement sum of `bytes` (a whole number of 4-byte words —
    /// FITS blocks always are), added to `initial`.
    public static func sum(_ bytes: Data, initial: UInt32 = 0) -> UInt32 {
        var hi = UInt64(initial >> 16), lo = UInt64(initial & 0xFFFF)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i + 3 < raw.count {
                hi += UInt64(raw[i]) << 8 | UInt64(raw[i + 1])
                lo += UInt64(raw[i + 2]) << 8 | UInt64(raw[i + 3])
                i += 4
            }
        }
        var hiCarry = hi >> 16, loCarry = lo >> 16
        while hiCarry != 0 || loCarry != 0 {
            hi = (hi & 0xFFFF) + loCarry
            lo = (lo & 0xFFFF) + hiCarry
            hiCarry = hi >> 16
            loCarry = lo >> 16
        }
        return UInt32(hi << 16 | lo)
    }

    /// Ones' complement addition of two sums.
    public static func add(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let total = UInt64(a) + UInt64(b)
        return UInt32(truncatingIfNeeded: (total & 0xFFFF_FFFF) + (total >> 32))
    }

    /// The 16 characters CHECKSUM holds for a sum: the complement,
    /// four characters a byte, avoiding ASCII punctuation, rotated one right.
    public static func encode(_ sum: UInt32) -> String {
        let value = ~sum
        let exclude: Set<Int> = [0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60]
        var ascii = [Int](repeating: 0, count: 16)
        for i in 0..<4 {
            let byte = Int((value >> (24 - 8 * UInt32(i))) & 0xFF)
            let quotient = byte / 4 + 0x30
            var ch = [quotient + byte % 4, quotient, quotient, quotient]
            var check = true
            while check {
                check = false
                for j in stride(from: 0, to: 4, by: 2) where exclude.contains(ch[j]) || exclude.contains(ch[j + 1]) {
                    ch[j] += 1
                    ch[j + 1] -= 1
                    check = true
                }
            }
            for j in 0..<4 { ascii[4 * j + i] = ch[j] }
        }
        return String((0..<16).map { Character(UnicodeScalar(UInt8(ascii[($0 + 15) % 16]))) })
    }
}
