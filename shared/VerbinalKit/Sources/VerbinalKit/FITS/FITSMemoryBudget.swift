// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether this machine can hold an image's pixels now, and what to say
/// when it cannot.
///
/// This was a fixed 500 million pixels, two answers wrong at once: a Mac
/// with 20 GB free was refused a mosaic it could hold with ease, and the
/// same number was all that stood between an 8 GB laptop and swapping to
/// a standstill. What decides it is the memory actually free.
///
/// The pixels (4 bytes each, whatever BITPIX says) are the only full-size
/// copy the viewer keeps — the file is mapped, and what is drawn is
/// `FITSDisplayRaster`'s picture, bounded whatever the image — so the
/// budget is the pixels plus a fixed allowance for everything else.
public enum FITSMemoryBudget {
    /// Always allowed however little is free, so every image that opened
    /// before still opens: a busy machine can page.
    public static let floor: Int64 = 512 * 1024 * 1024

    /// Kept back for the display picture and its bitmap (each at most
    /// `FITSDisplayRaster.maxPixels` × 4 bytes) and the app itself.
    public static let headroom: Int64 = 1024 * 1024 * 1024

    /// The most an image's pixels may take with this much free.
    public static func maxImageBytes(availableBytes: Int64) -> Int64 {
        max(floor, availableBytes - headroom)
    }

    /// Nil when a `width` × `height` image fits; otherwise what to tell the
    /// person — the whole of what opening it needs, headroom included, since
    /// "1.5 GB, and 1.5 GB is free" would read as a mistake.
    public static func refusal(width: Int, height: Int, availableBytes: Int64 = availableBytes()) -> String? {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        let pixelBytes = overflow ? Int64.max : Int64(count) * 4
        guard overflow || pixelBytes > maxImageBytes(availableBytes: availableBytes) else { return nil }
        let size = "\(width.formatted()) × \(height.formatted())"
        let needed = overflow ? "more memory than any computer has" : "about \(gigabytes(pixelBytes + headroom)) of memory"
        return "This image is \(size) pixels; opening it needs \(needed), and \(gigabytes(availableBytes)) is free. "
            + "Close other apps and open it again, or download a cutout of the part you need."
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1))) + " GB"
    }

    /// Memory that can be had now without paging: free, inactive and
    /// purgeable pages on the Mac; what the system allows this process on iOS.
    public static func availableBytes() -> Int64 {
        #if os(iOS)
        return Int64(os_proc_available_memory())
        #elseif canImport(Darwin)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Int64(ProcessInfo.processInfo.physicalMemory / 2) }
        let pages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.purgeable_count)
        return pages * Int64(vm_kernel_page_size)
        #else
        return Int64(ProcessInfo.processInfo.physicalMemory / 2)
        #endif
    }
}
