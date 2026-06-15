// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Ported from the v-cube web viewer (src/data/cubeModel.ts).

import Foundation

/// NaN-aware robust statistics over a cube (or a representative sample of it).
public struct CubeStats: Sendable, Equatable {
    public let lo: Float        // p0.1 — normalization floor
    public let hi: Float        // p99.9 — ceiling
    public let min: Float
    public let max: Float
    public let median: Float
    public let nanFrac: Float

    public init(lo: Float, hi: Float, min: Float, max: Float, median: Float, nanFrac: Float) {
        self.lo = lo; self.hi = hi; self.min = min; self.max = max
        self.median = median; self.nanFrac = nanFrac
    }
}

/// Downsampled half-float volume for the 3D texture. `data` holds `Float16`
/// values normalized onto (0, 1]; a stored 0 is the invalid/NaN sentinel.
public struct VolumeData: Sendable {
    public let data: [Float16]
    public let nx: Int, ny: Int, nz: Int
    public let binXY: Int, binZ: Int

    public init(data: [Float16], nx: Int, ny: Int, nz: Int, binXY: Int, binZ: Int) {
        self.data = data; self.nx = nx; self.ny = ny; self.nz = nz
        self.binXY = binXY; self.binZ = binZ
    }
}

public struct CubeIngestProgress: Sendable, Equatable {
    public let stage: String
    public let fraction: Double
    public init(stage: String, fraction: Double) {
        self.stage = stage; self.fraction = fraction
    }
}

/// Owns one loaded cube: header info, NaN-aware statistics, channel-plane access
/// (full-RAM for small cubes, LRU-streamed for big ones), and the downsampled
/// volume array for the 3D texture.
///
/// Normalization contract (shared by slice and volume rendering): raw values are
/// mapped linearly onto [0,1] over [stats.lo, stats.hi]; window + stretch are
/// applied downstream on that normalized value, so both modes always agree.
public actor CubeModel {
    // Immutable identity/metadata, set once in init — exposed nonisolated so UI
    // can read dimensions and header strings without hopping onto the actor.
    public nonisolated let nx: Int
    public nonisolated let ny: Int
    public nonisolated let nz: Int
    public nonisolated let bunit: String
    public nonisolated let object: String
    public nonisolated let telescope: String
    public nonisolated let instrument: String

    public private(set) var stats: CubeStats?
    public private(set) var wcs: CubeWCS?
    public private(set) var volume: VolumeData?

    private let source: CubeDataSource
    private let hdu: FITSHDUnit
    private let allHDUs: [FITSHDUnit]

    private var full: [Float]?              // entire cube when small enough
    private var cache: [Int: [Float]] = [:] // LRU plane cache otherwise
    private var lru: [Int] = []

    private static let fullRAMLimit = 320_000_000   // bytes of float32
    private static let planeCacheMax = 12

    private init(source: CubeDataSource, hdu: FITSHDUnit, allHDUs: [FITSHDUnit]) {
        self.source = source
        self.hdu = hdu
        self.allHDUs = allHDUs
        let h = hdu.header
        self.nx = h.naxis1
        self.ny = h.naxis2
        self.nz = h.int("NAXIS3")
        let primary = allHDUs.first?.header
        self.bunit = h.string("BUNIT") ?? primary?.string("BUNIT") ?? ""
        self.object = h.string("OBJECT") ?? primary?.string("OBJECT") ?? "—"
        self.telescope = h.string("TELESCOP") ?? primary?.string("TELESCOP") ?? ""
        self.instrument = h.string("INSTRUME") ?? primary?.string("INSTRUME") ?? ""
    }

    /// Open a cube from a data source: parse structure, pick the science cube HDU.
    public static func open(source: CubeDataSource) async throws -> CubeModel {
        let hdus = try await FITSCube.parseStructure(source: source)
        let cubes = FITSCube.findCubeHDUs(hdus)
        guard let sci = FITSCube.preferredCube(cubes) else {
            // Distinguish "it's a 2D image" from "no image at all" for a better message.
            if let twoD = hdus.first(where: { $0.header.naxis >= 2 && $0.header.naxis1 > 1 && $0.header.naxis2 > 1 }) {
                throw FITSError.invalidFile("\(source.name) is a 2D image (\(twoD.header.naxis1)×\(twoD.header.naxis2)), not a cube")
            }
            throw FITSError.invalidFile("No 3D cube HDU found in \(source.name)")
        }
        return CubeModel(source: source, hdu: sci, allHDUs: hdus)
    }

    public var isStreamed: Bool { full == nil }
    public var name: String { source.name }
    public var dimensions: (nx: Int, ny: Int, nz: Int) { (nx, ny, nz) }

    /// Acquire data + statistics, then build the volume texture array.
    /// - Parameters:
    ///   - max3D: max 3D-texture edge the GPU allows (spectral/spatial binning targets this).
    ///   - byteBudget: cap on the half-float volume size in bytes.
    public func ingest(
        max3D: Int,
        byteBudget: Int = 256_000_000,
        onProgress: @Sendable (CubeIngestProgress) -> Void
    ) async throws {
        self.wcs = await CubeWCS.build(source: source, hdus: allHDUs, hdu: hdu)
        let totalBytes = nx * ny * nz * 4
        let planeElems = nx * ny

        if totalBytes <= Self.fullRAMLimit {
            onProgress(.init(stage: "ACQUIRING DATA", fraction: 0))
            var buf = [Float](repeating: 0, count: planeElems * nz)
            for z in 0..<nz {
                let plane = try await FITSCube.extractPlane(source: source, hdu: hdu, channel: z)
                buf.withUnsafeMutableBufferPointer { dst in
                    plane.withUnsafeBufferPointer { src in
                        dst.baseAddress!.advanced(by: z * planeElems).update(from: src.baseAddress!, count: planeElems)
                    }
                }
                if z % 8 == 0 || z == nz - 1 {
                    onProgress(.init(stage: "ACQUIRING DATA", fraction: Double(z + 1) / Double(nz)))
                    await Task.yield()
                }
            }
            full = buf
            onProgress(.init(stage: "COMPUTING STATISTICS", fraction: 0))
            stats = Self.computeStats(buf)
        } else {
            // Streamed cube: sample planes for statistics, never hold it all.
            onProgress(.init(stage: "SAMPLING STATISTICS", fraction: 0))
            let samplePlanes = 24
            var samples: [Float] = []
            for i in 0..<samplePlanes {
                let z = nz <= 1 ? 0 : Int((Double(i) / Double(samplePlanes - 1)) * Double(nz - 1))
                samples.append(contentsOf: try await FITSCube.extractPlane(source: source, hdu: hdu, channel: z))
                onProgress(.init(stage: "SAMPLING STATISTICS", fraction: Double(i + 1) / Double(samplePlanes)))
                await Task.yield()
            }
            stats = Self.computeStats(samples)
        }

        try await buildVolume(max3D: max3D, byteBudget: byteBudget, onProgress: onProgress)
    }

    /// Channel plane for slice rendering (cached for streamed cubes).
    public func plane(_ z: Int) async throws -> [Float] {
        guard z >= 0, z < nz else { throw FITSError.invalidFile("Channel \(z) out of range") }
        if let full {
            let planeElems = nx * ny
            return Array(full[(z * planeElems)..<((z + 1) * planeElems)])
        }
        if let hit = cache[z] {
            touchLRU(z)
            return hit
        }
        let plane = try await FITSCube.extractPlane(source: source, hdu: hdu, channel: z)
        cache[z] = plane
        lru.append(z)
        if lru.count > Self.planeCacheMax, let evict = lru.first {
            lru.removeFirst()
            cache.removeValue(forKey: evict)
        }
        return plane
    }

    /// Exact raw value at voxel (0-based). Reads from RAM or the plane cache;
    /// returns NaN for out-of-range or an uncached streamed plane.
    public func valueAt(x: Int, y: Int, z: Int) -> Float {
        guard x >= 0, y >= 0, x < nx, y < ny, z >= 0, z < nz else { return .nan }
        if let full { return full[z * nx * ny + y * nx + x] }
        if let p = cache[z] { return p[y * nx + x] }
        return .nan
    }

    /// Spectrum through (x, y) — RAM cubes only (streamed would mean a full scan).
    public func spectrum(x: Int, y: Int) -> [Float]? {
        guard let full, x >= 0, y >= 0, x < nx, y < ny else { return nil }
        let stride = nx * ny
        var out = [Float](repeating: 0, count: nz)
        for z in 0..<nz { out[z] = full[z * stride + y * nx + x] }
        return out
    }

    private func touchLRU(_ z: Int) {
        if let idx = lru.firstIndex(of: z) {
            lru.remove(at: idx)
            lru.append(z)
        }
    }

    /// Build the volume-mode array: spectral binning to fit `max3D`, spatial
    /// binning to fit the byte budget, NaN-aware mean, half-float quantization
    /// over [lo, hi] with 0 reserved as the invalid sentinel.
    private func buildVolume(
        max3D: Int,
        byteBudget: Int,
        onProgress: @Sendable (CubeIngestProgress) -> Void
    ) async throws {
        guard let stats else { return }
        let binZ = Swift.max(ceilDiv(nz, Swift.min(max3D, 2048)), 1)
        var binXY = Swift.max(ceilDiv(nx, max3D), ceilDiv(ny, max3D), 1)
        let oNz = ceilDiv(nz, binZ)
        while ceilDiv(nx, binXY) * ceilDiv(ny, binXY) * oNz * 2 > byteBudget { binXY += 1 }
        let oNx = ceilDiv(nx, binXY)
        let oNy = ceilDiv(ny, binXY)

        var data = [Float16](repeating: 0, count: oNx * oNy * oNz)
        var sum = [Float](repeating: 0, count: oNx * oNy)
        var cnt = [Int32](repeating: 0, count: oNx * oNy)
        let range = (stats.hi - stats.lo) == 0 ? 1 : (stats.hi - stats.lo)
        let eps: Float = 1.0 / 2048   // keep valid values away from the 0 sentinel

        // Hoist per-column output index out of the inner loop.
        var xo = [Int](repeating: 0, count: nx)
        for x in 0..<nx { xo[x] = x / binXY }

        for zo in 0..<oNz {
            for i in 0..<(oNx * oNy) { sum[i] = 0; cnt[i] = 0 }
            let z0 = zo * binZ
            let z1 = Swift.min(z0 + binZ, nz)
            for z in z0..<z1 {
                let plane = try await plane(z)
                plane.withUnsafeBufferPointer { p in
                    for y in 0..<ny {
                        let rowIn = y * nx
                        let rowOut = (y / binXY) * oNx
                        for x in 0..<nx {
                            let v = p[rowIn + x]
                            if v == v {   // not NaN
                                let idx = rowOut + xo[x]
                                sum[idx] += v
                                cnt[idx] += 1
                            }
                        }
                    }
                }
            }
            let slab = zo * oNx * oNy
            for i in 0..<(oNx * oNy) {
                if cnt[i] == 0 { continue }   // stays 0 = invalid
                var t = (sum[i] / Float(cnt[i]) - stats.lo) / range
                t = t < 0 ? 0 : (t > 1 ? 1 : t)
                data[slab + i] = Float16(eps + t * (1 - eps))
            }
            if zo % 8 == 0 || zo == oNz - 1 {
                onProgress(.init(stage: "BUILDING VOLUME", fraction: Double(zo + 1) / Double(oNz)))
                await Task.yield()
            }
        }
        volume = VolumeData(data: data, nx: oNx, ny: oNy, nz: oNz, binXY: binXY, binZ: binZ)
    }

    // MARK: - Statistics

    /// NaN-aware robust percentile statistics over a sampled subset.
    static func computeStats(_ data: [Float]) -> CubeStats {
        let maxSample = 4_000_000
        let stride = Swift.max(1, data.count / maxSample)
        var finite: [Float] = []
        finite.reserveCapacity(data.count / stride + 1)
        var nan = 0, seen = 0
        var i = 0
        while i < data.count {
            let v = data[i]
            seen += 1
            if v == v { finite.append(v) } else { nan += 1 }
            i += stride
        }
        if finite.isEmpty {
            return CubeStats(lo: 0, hi: 1, min: 0, max: 1, median: 0, nanFrac: 1)
        }
        finite.sort()
        let n = finite.count
        func q(_ f: Double) -> Float { finite[Swift.min(n - 1, Swift.max(0, Int((f * Double(n - 1)).rounded())))] }
        var lo = q(0.001)
        var hi = q(0.999)
        if hi <= lo { lo = finite[0]; hi = finite[n - 1] }
        if hi <= lo { hi = lo + (abs(lo) == 0 ? 1 : abs(lo)) }   // constant cube
        return CubeStats(lo: lo, hi: hi, min: finite[0], max: finite[n - 1],
                         median: q(0.5), nanFrac: Float(nan) / Float(seen))
    }
}

private func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / Swift.max(b, 1) }
