// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Ported from the v-cube web viewer (src/fits/wcs.ts). Just enough WCS for
// trustworthy cube readouts: celestial TAN/CAR (equatorial or galactic) and a
// spectral 3rd axis with frequency→velocity and wavenumber→nm conveniences.

import Foundation

/// Spectral (3rd-axis) world coordinates: linear CRVAL3/CDELT3 or a per-channel
/// lookup table (WAVE-TAB), formatted with unit-aware readouts.
public struct SpectralWCS: Sendable {
    public let ctype: String       // FREQ, WAVE, WAVE-TAB, WAVN, VRAD, …
    public let cunit: String
    public let restfrq: Double?    // Hz, for FREQ→radio-velocity
    public let table: [Double]?    // per-channel values when tabular
    public let crval: Double
    public let crpix: Double
    public let cdelt: Double

    public init(ctype: String, cunit: String, restfrq: Double?, table: [Double]?,
                crval: Double, crpix: Double, cdelt: Double) {
        self.ctype = ctype
        self.cunit = cunit
        self.restfrq = restfrq
        self.table = table
        self.crval = crval
        self.crpix = crpix
        self.cdelt = cdelt
    }

    public struct Readout: Sendable, Equatable {
        public let primary: String      // e.g. "230.53800 GHz" / "5.3402 µm"
        public let secondary: String?   // e.g. "-12.40 km/s" / "λ 657.30 nm"
        public let axisLabel: String    // scrubber label, e.g. "VELOCITY km/s"
        public init(primary: String, secondary: String?, axisLabel: String) {
            self.primary = primary
            self.secondary = secondary
            self.axisLabel = axisLabel
        }
    }

    /// Channel index (0-based) → physical spectral value in native units.
    public func value(atChannel channel: Int) -> Double {
        if let table, !table.isEmpty {
            let i = Swift.min(table.count - 1, Swift.max(0, channel))
            return table[i]
        }
        return crval + (Double(channel) + 1 - crpix) * cdelt
    }

    public func format(channel: Int) -> Readout {
        let v = value(atChannel: channel)
        let t = ctype.uppercased()
        let cKMS = 299_792.458

        if t.hasPrefix("FREQ") {
            let hz = cunit == "GHz" ? v * 1e9 : (cunit == "MHz" ? v * 1e6 : v)
            let vel = restfrq.map { cKMS * (1 - hz / $0) }
            return Readout(primary: String(format: "%.5f GHz", hz / 1e9),
                           secondary: vel.map { String(format: "%.2f km/s", $0) },
                           axisLabel: restfrq != nil ? "VELOCITY km/s" : "FREQ GHz")
        }
        if t.hasPrefix("WAVN") {
            let nm = v != 0 ? 1e7 / v : 0
            return Readout(primary: String(format: "%.3f cm⁻¹", v),
                           secondary: String(format: "λ %.2f nm", nm),
                           axisLabel: "WAVENUMBER cm⁻¹")
        }
        if t.hasPrefix("WAVE") {
            let lc = cunit.lowercased()
            let um = cunit == "m" ? v * 1e6 : (lc == "angstrom" ? v * 1e-4 : (cunit == "nm" ? v * 1e-3 : v))
            return Readout(primary: String(format: "%.4f µm", um), secondary: nil, axisLabel: "WAVELENGTH µm")
        }
        if t.hasPrefix("VRAD") || t.hasPrefix("VELO") || t.hasPrefix("VOPT") {
            let u = cunit.trimmingCharacters(in: .whitespaces).lowercased()
            let kms = u.hasPrefix("km") ? v : v / 1000   // FITS default velocity unit is m/s
            return Readout(primary: String(format: "%.2f km/s", kms), secondary: nil, axisLabel: "VELOCITY km/s")
        }
        if t.hasPrefix("FDEP") || t.hasPrefix("FARADAY") {
            return Readout(primary: String(format: "%@%.2f rad/m²", v >= 0 ? "+" : "", v),
                           secondary: nil, axisLabel: "FARADAY DEPTH rad/m²")
        }
        return Readout(primary: String(format: "%.6g", v), secondary: nil,
                       axisLabel: ctype.isEmpty ? "CHANNEL" : ctype)
    }
}

/// Celestial (axes 1–2) world coordinates for cubes: TAN or CAR projection,
/// equatorial or galactic frame, CD or PC·CDELT matrix. A focused companion to
/// the 2D `FITSWCSTransform`, tuned for the radio/IR cube corpus (galactic, CAR).
public struct CelestialWCS: Sendable {
    public enum Projection: Sendable { case tan, car }
    public enum Frame: Sendable { case equatorial, galactic }

    public let valid: Bool
    public let projection: Projection
    public let frame: Frame
    public let crval1: Double, crval2: Double
    public let crpix1: Double, crpix2: Double
    public let cd11: Double, cd12: Double, cd21: Double, cd22: Double   // deg/px

    public init(valid: Bool, projection: Projection, frame: Frame,
                crval1: Double, crval2: Double, crpix1: Double, crpix2: Double,
                cd11: Double, cd12: Double, cd21: Double, cd22: Double) {
        self.valid = valid
        self.projection = projection
        self.frame = frame
        self.crval1 = crval1; self.crval2 = crval2
        self.crpix1 = crpix1; self.crpix2 = crpix2
        self.cd11 = cd11; self.cd12 = cd12; self.cd21 = cd21; self.cd22 = cd22
    }

    public struct SkyReadout: Sendable, Equatable {
        public let lonLabel: String
        public let latLabel: String
        public let lon: String
        public let lat: String
        public init(lonLabel: String, latLabel: String, lon: String, lat: String) {
            self.lonLabel = lonLabel
            self.latLabel = latLabel
            self.lon = lon
            self.lat = lat
        }
    }

    /// Pixel (0-based) → (lon, lat) degrees, or nil when WCS is absent.
    public func pixelToSky(x: Double, y: Double) -> (lon: Double, lat: Double)? {
        guard valid else { return nil }
        let d2r = Double.pi / 180
        let dx = x + 1 - crpix1
        let dy = y + 1 - crpix2

        if projection == .car {
            // Plate carrée with reference on the equator: world = crval + intermediate.
            var lon = crval1 + cd11 * dx + cd12 * dy
            let lat = crval2 + cd21 * dx + cd22 * dy
            lon = (lon.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            return (lon, lat)
        }

        let xi = (cd11 * dx + cd12 * dy) * d2r
        let eta = (cd21 * dx + cd22 * dy) * d2r
        let ra0 = crval1 * d2r
        let dec0 = crval2 * d2r
        let den = cos(dec0) - eta * sin(dec0)
        let alpha = ra0 + atan2(xi, den)
        let delta = atan2(sin(dec0) + eta * cos(dec0), (xi * xi + den * den).squareRoot())
        var lon = alpha / d2r
        if lon < 0 { lon += 360 }
        if lon >= 360 { lon -= 360 }
        return (lon, delta / d2r)
    }

    /// Frame-aware formatting: equatorial → sexagesimal, galactic → decimal ℓ/b.
    public func formatSky(lon: Double, lat: Double) -> SkyReadout {
        if frame == .galactic {
            return SkyReadout(lonLabel: "GLON", latLabel: "GLAT",
                              lon: String(format: "%.3f°", lon),
                              lat: String(format: "%@%.3f°", lat >= 0 ? "+" : "−", abs(lat)))
        }
        return SkyReadout(lonLabel: "RA", latLabel: "DEC",
                          lon: FITSWCSTransform.formatRA(lon),
                          lat: FITSWCSTransform.formatDec(lat))
    }

    static func from(header h: FITSHeader) -> CelestialWCS {
        let ctype1 = h.string("CTYPE1") ?? ""
        let valid = ctype1.hasPrefix("RA-") || ctype1.hasPrefix("GLON")
        let projection: Projection = ctype1.contains("-CAR") ? .car : .tan
        let frame: Frame = ctype1.hasPrefix("GLON") ? .galactic : .equatorial
        let cdelt1 = h.double("CDELT1", fallback: 1)
        let cdelt2 = h.double("CDELT2", fallback: 1)

        var cd11 = h.contains("CD1_1") ? h.double("CD1_1") : Double.nan
        var cd12 = h.double("CD1_2", fallback: 0)
        var cd21 = h.double("CD2_1", fallback: 0)
        var cd22 = h.contains("CD2_2") ? h.double("CD2_2") : Double.nan
        if cd11.isNaN || cd22.isNaN {
            // Fall back to PC·CDELT (or plain CDELT when PC absent).
            let pc11 = h.double("PC1_1", fallback: 1)
            let pc12 = h.double("PC1_2", fallback: 0)
            let pc21 = h.double("PC2_1", fallback: 0)
            let pc22 = h.double("PC2_2", fallback: 1)
            cd11 = pc11 * cdelt1; cd12 = pc12 * cdelt1
            cd21 = pc21 * cdelt2; cd22 = pc22 * cdelt2
        }

        return CelestialWCS(valid: valid, projection: projection, frame: frame,
                            crval1: h.double("CRVAL1"), crval2: h.double("CRVAL2"),
                            crpix1: h.double("CRPIX1", fallback: 1), crpix2: h.double("CRPIX2", fallback: 1),
                            cd11: cd11, cd12: cd12, cd21: cd21, cd22: cd22)
    }
}

/// Combined cube WCS (celestial + spectral) built from the chosen HDU.
public struct CubeWCS: Sendable {
    public let spectral: SpectralWCS
    public let celestial: CelestialWCS

    public init(spectral: SpectralWCS, celestial: CelestialWCS) {
        self.spectral = spectral
        self.celestial = celestial
    }

    /// Build from the chosen cube HDU; resolves a WAVE-TAB table when present.
    public static func build(source: CubeDataSource, hdus: [FITSHDUnit], hdu: FITSHDUnit) async -> CubeWCS {
        let h = hdu.header
        let ctype3 = (h.string("CTYPE3") ?? "").trimmingCharacters(in: .whitespaces)

        var table: [Double]? = nil
        if ctype3.contains("-TAB") {
            let tableExt = h.string("PS3_0") ?? "WCS-TABLE"
            let colName = h.string("PS3_1") ?? "wavelength"
            if let ext = hdus.first(where: { ($0.header.string("EXTNAME") ?? "") == tableExt }) {
                table = try? await FITSCube.readBintableColumn(source: source, hdu: ext, column: colName)
            }
        }

        let restfrq: Double? = h.contains("RESTFRQ") ? h.double("RESTFRQ")
            : (h.contains("RESTFREQ") ? h.double("RESTFREQ") : nil)

        let spectral = SpectralWCS(
            ctype: ctype3,
            cunit: (h.string("CUNIT3") ?? "").trimmingCharacters(in: .whitespaces),
            restfrq: restfrq,
            table: table,
            crval: h.double("CRVAL3"),
            crpix: h.double("CRPIX3", fallback: 1),
            cdelt: h.contains("CDELT3") ? h.double("CDELT3") : h.double("CD3_3", fallback: 1)
        )
        return CubeWCS(spectral: spectral, celestial: .from(header: h))
    }
}
