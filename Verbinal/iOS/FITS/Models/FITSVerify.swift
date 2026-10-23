// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Is it right? — what the FITS viewer's Verify tab checks (plan 47 4.3), from
/// the file's own bytes and values; nothing here changes them.
enum FITSVerify {
    // MARK: - Whole

    enum Integrity: Equatable, Sendable {
        /// DATASUM and CHECKSUM both match the bytes.
        case intact
        /// What does not match.
        case damaged(String)
        /// The HDU carries neither.
        case noChecksum
        /// Not checked here, and why.
        case notChecked(String)
    }

    /// Where each HDU's header starts: the file's start, then the end of the
    /// HDU before it, its data padded to a whole 2880-byte block.
    static func headerStarts(_ hdus: [FITSHDUnit]) -> [Int] {
        var starts: [Int] = []
        var next = 0
        for hdu in hdus {
            starts.append(next)
            next = hdu.dataOffset + (hdu.dataLength + 2879) / 2880 * 2880
        }
        return starts
    }

    /// Checks an HDU's DATASUM (its data's ones' complement sum) and
    /// CHECKSUM (the whole HDU sums to all ones), from `bytes`, the file.
    static func integrity(of hdu: FITSHDUnit, headerStart: Int, in bytes: Data) -> Integrity {
        let header = hdu.header
        guard hdu.compression == nil else {
            return .notChecked(String(localized: "A tile-compressed image's checksums are on its table."))
        }
        let datasum = header.string("DATASUM").flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
        let hasChecksum = header.contains("CHECKSUM")
        guard datasum != nil || hasChecksum else { return .noChecksum }
        let dataEnd = hdu.dataOffset + hdu.dataLength
        guard headerStart >= 0, headerStart <= hdu.dataOffset, dataEnd <= bytes.count else {
            return .notChecked(String(localized: "The file is shorter than its headers say."))
        }
        // The padding is zeros: it adds nothing to a sum.
        let dataSum = FITSChecksum.sum(bytes.subdata(in: hdu.dataOffset..<dataEnd))
        if let datasum, datasum != dataSum {
            return .damaged(String(localized: "DATASUM is \(String(datasum)), the data sum to \(String(dataSum))."))
        }
        if hasChecksum {
            let headerSum = FITSChecksum.sum(bytes.subdata(in: headerStart..<hdu.dataOffset))
            if FITSChecksum.add(headerSum, dataSum) != 0xFFFF_FFFF {
                return .damaged(String(localized: "CHECKSUM does not match the HDU."))
            }
        }
        return .intact
    }

    // MARK: - Values

    struct Stats: Equatable, Sendable {
        var count = 0
        /// Not a number: blank pixels.
        var blank = 0
        var min: Float = .nan
        var max: Float = .nan
        var mean: Double = .nan
        var sigma: Double = .nan
        var median: Float = .nan
        /// The median came from an even sample of the pixels, not all of them.
        var medianSampled = false
        /// Pixels at or above SATURATE, when the header gives it.
        var saturated: Int?
    }

    /// A median from at most this many pixels.
    static let medianSample = 1_000_000

    static func stats(_ pixels: [Float], saturate: Float? = nil) -> Stats {
        var stats = Stats(count: pixels.count)
        var lo = Float.infinity, hi = -Float.infinity
        var sum = 0.0, squares = 0.0, finite = 0, saturated = 0
        for value in pixels {
            guard value.isFinite else { stats.blank += 1; continue }
            finite += 1
            if value < lo { lo = value }
            if value > hi { hi = value }
            let double = Double(value)
            sum += double
            squares += double * double
            if let saturate, value >= saturate { saturated += 1 }
        }
        guard finite > 0 else { return stats }
        stats.min = lo
        stats.max = hi
        stats.mean = sum / Double(finite)
        stats.sigma = (Swift.max(0, squares / Double(finite) - stats.mean * stats.mean)).squareRoot()
        stats.saturated = saturate == nil ? nil : saturated
        let sample = evenSample(pixels, limit: medianSample).sorted()
        stats.median = sample.isEmpty ? .nan : sample[sample.count / 2]
        stats.medianSampled = finite > medianSample
        return stats
    }

    /// The cuts that keep the middle `kept` share of the values (0.995: a
    /// quarter percent clipped at each end), from an even sample.
    static func percentileCut(_ pixels: [Float], kept: Double) -> (min: Float, max: Float)? {
        let sample = evenSample(pixels, limit: medianSample).sorted()
        guard sample.count > 1 else { return nil }
        let clip = (1 - kept) / 2
        let lo = sample[Int(Double(sample.count - 1) * clip)]
        let hi = sample[Int(Double(sample.count - 1) * (1 - clip))]
        return lo < hi ? (lo, hi) : nil
    }

    /// How many values fall in each of `bins` equal steps from `lo` to `hi`,
    /// from an even sample.
    static func histogram(_ pixels: [Float], lo: Float, hi: Float, bins: Int) -> [Int] {
        guard bins > 0, hi > lo else { return [] }
        var counts = [Int](repeating: 0, count: bins)
        let scale = Float(bins) / (hi - lo)
        for value in evenSample(pixels, limit: medianSample) where value >= lo && value <= hi {
            counts[Swift.min(bins - 1, Int((value - lo) * scale))] += 1
        }
        return counts
    }

    /// Finite values, every n-th, at most `limit` of them.
    static func evenSample(_ pixels: [Float], limit: Int) -> [Float] {
        let step = Swift.max(1, pixels.count / Swift.max(1, limit))
        var sample: [Float] = []
        sample.reserveCapacity(Swift.min(pixels.count, limit) + 1)
        var index = 0
        while index < pixels.count {
            let value = pixels[index]
            if value.isFinite { sample.append(value) }
            index += step
        }
        return sample
    }
}
