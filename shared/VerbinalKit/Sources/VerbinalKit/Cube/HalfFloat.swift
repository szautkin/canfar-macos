// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

// Portable IEEE-754 binary16 (half-float) conversions.
//
// The `Float16` type is UNAVAILABLE on x86_64 macOS, so a universal build
// (arm64 + x86_64 — what an App Store archive produces) cannot use it. The
// cube's 3D texture is `.r16Float`, which consumes the raw 16-bit half-float
// bit pattern regardless of the Swift type, so the volume is stored and
// converted as `UInt16` bits here instead of `Float16`.

/// Convert a Float32 to the raw binary16 bit pattern (round-to-nearest-even).
@inline(__always)
public func floatToHalfBits(_ value: Float) -> UInt16 {
    let x = value.bitPattern
    let sign = UInt16((x >> 16) & 0x8000)
    let exp = Int32((x >> 23) & 0xFF)
    let mantissa = x & 0x007F_FFFF

    if exp == 0xFF {                                  // Inf / NaN
        return sign | (mantissa != 0 ? 0x7E00 : 0x7C00)
    }
    let e = exp - 127 + 15                            // re-bias to half
    if e >= 0x1F { return sign | 0x7C00 }             // overflow → ±Inf
    if e <= 0 {                                       // subnormal / underflow
        if e < -10 { return sign }                    // too small → ±0
        let m = mantissa | 0x0080_0000                // restore implicit 1
        let shift = UInt32(14 - e)
        var half = m >> shift
        if (m >> (shift - 1)) & 1 != 0 { half += 1 }  // round to nearest
        return sign | UInt16(truncatingIfNeeded: half)
    }
    var half = UInt32(e << 10) | (mantissa >> 13)     // normal
    let round = mantissa & 0x1FFF
    if round > 0x1000 || (round == 0x1000 && half & 1 != 0) { half += 1 }
    return sign | UInt16(truncatingIfNeeded: half)
}

/// Convert a raw binary16 bit pattern back to Float32.
@inline(__always)
public func halfBitsToFloat(_ bits: UInt16) -> Float {
    let sign = UInt32(bits & 0x8000) << 16
    let exp = UInt32(bits >> 10) & 0x1F
    let mantissa = UInt32(bits & 0x03FF)

    if exp == 0 {
        if mantissa == 0 { return Float(bitPattern: sign) }   // ±0
        var e: UInt32 = 0                                     // subnormal → normalize
        var m = mantissa
        while m & 0x0400 == 0 { m <<= 1; e += 1 }
        m &= 0x03FF
        return Float(bitPattern: sign | ((127 - 15 - e + 1) << 23) | (m << 13))
    }
    if exp == 0x1F {                                          // Inf / NaN
        return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
    }
    return Float(bitPattern: sign | ((exp + 127 - 15) << 23) | (mantissa << 13))
}
