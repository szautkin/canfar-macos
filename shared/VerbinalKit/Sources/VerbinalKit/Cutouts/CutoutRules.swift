// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One thing about a cutout the rules have to say.
public enum CutoutIssue: Equatable, Hashable, Sendable {
    case nothingToCut
    case region(SkyRegion.Problem)
    case noRegionShape
    case outsideFootprint
    case partlyOutsideFootprint
    case noBand, bandOrder, bandOutside, bandPartial
    case noTime, timeOrder, timeOutside, timePartial
    case noPol
    case polUnknown(String, available: [String])
    /// A local cut: the file has no image by that name.
    case unknownImage(String, available: [String])
    /// A local cut: this way cannot choose among images (CADC's cut keeps every one).
    case noImageChoice
    /// A local cut: the file on this computer could not be read.
    case unreadable(String)

    /// English — what an agent is told; the app has its own translation.
    public var message: String {
        switch self {
        case .nothingToCut: return "Choose a region (or a band) to cut; with neither, the whole file would come back."
        case .region(let problem):
            switch problem {
            case .notANumber: return "The position and size have to be numbers."
            case .decOutOfRange: return "Dec has to be between −90° and +90°."
            case .sizeNotPositive: return "The size has to be greater than zero."
            case .tooLarge: return "That region is larger than any cutout can be."
            case .tooFewVertices: return "A polygon needs at least three corners."
            case .degenerate: return "Those corners enclose no area."
            }
        case .noRegionShape: return "This file cannot be cut to that shape."
        case .outsideFootprint: return "That region is outside this file's footprint."
        case .partlyOutsideFootprint: return "Part of that region is outside the footprint; the cutout will be trimmed to it."
        case .noBand: return "This file cannot be cut by wavelength."
        case .bandOrder: return "The shortest wavelength has to be below the longest."
        case .bandOutside: return "That wavelength range is outside this file's."
        case .bandPartial: return "Part of that wavelength range is outside this file's; the cutout will be trimmed to it."
        case .noTime: return "This file cannot be cut by time."
        case .timeOrder: return "The start has to be before the end."
        case .timeOutside: return "That time range is outside this file's."
        case .timePartial: return "Part of that time range is outside this file's; the cutout will be trimmed to it."
        case .noPol: return "This file cannot be cut by polarization."
        case .polUnknown(let state, let available): return "This file has no \(state) polarization; it has \(available.joined(separator: ", "))."
        case .unknownImage(let name, let available): return "This file has no image \(name); it has \(available.joined(separator: ", "))."
        case .noImageChoice: return "This way of cutting cannot choose among the file's images; it keeps every image the region falls on."
        case .unreadable(let why): return "The file on this computer could not be read: \(why)"
        }
    }
}

/// What the rules say about a cutout: errors stop it, warnings only say
/// what will happen.
public struct CutoutCheck: Equatable, Sendable {
    public let errors: [CutoutIssue]
    public let warnings: [CutoutIssue]
    public var isValid: Bool { errors.isEmpty }

    public init(errors: [CutoutIssue], warnings: [CutoutIssue]) {
        self.errors = errors
        self.warnings = warnings
    }
}

/// The rules every cutout is held to, whoever cuts it: there is something
/// to cut; the region is a region; the file can be cut to that shape, band,
/// time and polarization; and they fall on the file. The one place they are
/// judged, so the editor, an agent's request and the cut cannot disagree.
public enum CutoutRules {

    public static func check(_ spec: CutoutSpec, against file: CutoutFile) -> CutoutCheck {
        var errors: [CutoutIssue] = []
        var warnings: [CutoutIssue] = []
        if spec.isEmpty { errors.append(.nothingToCut) }
        if let region = spec.region { checkRegion(region, file, &errors, &warnings) }
        if spec.bandMin != nil || spec.bandMax != nil {
            checkInterval(file.supports("BAND"), spec.bandMin, spec.bandMax, file.bandMin, file.bandMax,
                          (.noBand, .bandOrder, .bandOutside, .bandPartial), &errors, &warnings)
        }
        if spec.timeMin != nil || spec.timeMax != nil {
            checkInterval(file.supports("TIME"), spec.timeMin, spec.timeMax, file.timeMin, file.timeMax,
                          (.noTime, .timeOrder, .timeOutside, .timePartial), &errors, &warnings)
        }
        if !spec.extensions.isEmpty && file.images.isEmpty { errors.append(.noImageChoice) }
        if !spec.pol.isEmpty {
            if !file.supports("POL") {
                errors.append(.noPol)
            } else if !file.polStates.isEmpty, let unknown = spec.pol.first(where: { !file.polStates.contains($0) }) {
                errors.append(.polUnknown(unknown, available: file.polStates))
            }
        }
        return CutoutCheck(errors: errors, warnings: warnings)
    }

    private static func checkRegion(_ region: SkyRegion, _ file: CutoutFile,
                                    _ errors: inout [CutoutIssue], _ warnings: inout [CutoutIssue]) {
        if let problem = region.problem { errors.append(.region(problem)); return }
        guard file.supports(region.sodaParameter) else { errors.append(.noRegionShape); return }
        guard let footprint = file.footprint else { return }
        switch SkyGeometry.overlap(region.outline(), footprint.outline()) {
        case .outside: errors.append(.outsideFootprint)
        case .partial: warnings.append(.partlyOutsideFootprint)
        case .inside: break
        }
    }

    private static func checkInterval(_ supported: Bool, _ min: Double?, _ max: Double?, _ fileMin: Double?, _ fileMax: Double?,
                                      _ issues: (none: CutoutIssue, order: CutoutIssue, outside: CutoutIssue, partial: CutoutIssue),
                                      _ errors: inout [CutoutIssue], _ warnings: inout [CutoutIssue]) {
        guard supported else { errors.append(issues.none); return }
        if let a = min, let b = max, a >= b { errors.append(issues.order); return }
        let lo = min ?? fileMin ?? -.infinity, hi = max ?? fileMax ?? .infinity
        let fLo = fileMin ?? -.infinity, fHi = fileMax ?? .infinity
        if hi <= fLo || lo >= fHi { errors.append(issues.outside) } else if lo < fLo || hi > fHi { warnings.append(issues.partial) }
    }
}

/// The SODA request made from a cutout, and how large CADC's answer will be.
public enum SodaRequest {

    public enum Failure: Error, Equatable {
        /// The cutout was refused by the rules: a URL for it would be a bug.
        case refused(CutoutIssue)
    }

    /// SODA's sync endpoint with the file's ID and one value for each
    /// parameter the cutout sets — for a cutout the rules accept.
    public static func url(_ file: SodaDescriptor, _ spec: CutoutSpec) throws(Failure) -> URL {
        let check = CutoutRules.check(spec, against: file)
        if let first = check.errors.first { throw .refused(first) }
        var query = [("ID", file.artifactID)]
        if let region = spec.region { query.append((region.sodaParameter, region.sodaValue)) }
        if spec.bandMin != nil || spec.bandMax != nil { query.append(("BAND", range(spec.bandMin, spec.bandMax))) }
        if spec.timeMin != nil || spec.timeMax != nil { query.append(("TIME", range(spec.timeMin, spec.timeMax))) }
        query += spec.pol.map { ("POL", $0) }
        // Everything but RFC 3986's unreserved characters is escaped, as Windows does.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
        let separator = file.accessURL.contains("?") ? "&" : "?"
        guard let url = URL(string: file.accessURL + separator + encoded.joined(separator: "&")) else {
            throw .refused(.nothingToCut)
        }
        return url
    }

    /// About how large the cutout will be: the whole file in proportion to
    /// the share of its footprint the cut covers, and of its band the band
    /// does. An estimate for a person deciding, not a promise; nil with
    /// nothing to go on.
    public static func estimatedBytes(_ file: CutoutFile, _ spec: CutoutSpec, wholeFile: Int64?) -> Int64? {
        guard let whole = wholeFile, whole > 0 else { return nil }
        var share = 1.0
        if let region = spec.region, let footprint = file.footprint {
            let area = SkyGeometry.area(footprint.outline())
            if area > 0 { share *= Swift.min(1, boundingArea(region) / area) }
        }
        if let lo = file.bandMin, let hi = file.bandMax, hi > lo {
            let from = Swift.max(lo, spec.bandMin ?? lo), to = Swift.min(hi, spec.bandMax ?? hi)
            share *= Swift.min(Swift.max((to - from) / (hi - lo), 0), 1)
        }
        return Int64(Double(whole) * share)
    }

    /// SODA returns the pixel box around a region, not the region: a circle
    /// comes back as its square (measured on a MegaPipe tile).
    private static func boundingArea(_ region: SkyRegion) -> Double {
        let centre = region.centre
        let plane = region.outline().compactMap { SkyGeometry.project($0, about: centre) }
        guard let minX = plane.map(\.x).min(), let maxX = plane.map(\.x).max(),
              let minY = plane.map(\.y).min(), let maxY = plane.map(\.y).max() else { return 0 }
        return (maxX - minX) * (maxY - minY)
    }

    /// An open end is written as infinity, as SODA's interval syntax has it.
    private static func range(_ min: Double?, _ max: Double?) -> String {
        "\(min.map { "\($0)" } ?? "-Inf") \(max.map { "\($0)" } ?? "+Inf")"
    }
}

/// What a search already knows that a cutout can start from: where it
/// looked, how far out, and the wavelengths it asked for — degrees and metres.
public struct CutoutHints: Equatable, Sendable {
    public var ra: Double?
    public var dec: Double?
    public var radius: Double?
    public var bandMin: Double?
    public var bandMax: Double?

    public init(ra: Double? = nil, dec: Double? = nil, radius: Double? = nil, bandMin: Double? = nil, bandMax: Double? = nil) {
        self.ra = ra
        self.dec = dec
        self.radius = radius
        self.bandMin = bandMin
        self.bandMax = bandMax
    }
}

/// The cutout an editor opens on, so the person adjusts a sensible one:
/// the search's target at its radius when it falls on the file, its
/// wavelengths when the file can be cut by them — otherwise a circle at the
/// middle of the file, a quarter of it across. Always within the file.
public enum CutoutPrefill {
    /// Never smaller than this, so a pinpoint search radius still makes a cutout worth having.
    public static let minimumRadius = 5.0 / 3600

    public static func suggest(_ file: CutoutFile, hints: CutoutHints? = nil) -> CutoutSpec {
        let band = suggestBand(file, hints)
        return CutoutSpec(artifactID: file.artifactID, region: suggestRegion(file, hints), bandMin: band.0, bandMax: band.1)
    }

    /// The cutout a search's "Spatial cutout" and "Spectral cutout" boxes
    /// ask for, for one of its results: the search's circle and wavelengths.
    /// Nil when they ask for nothing this file can give — then the whole
    /// file is what was asked for.
    public static func fromSearchFlags(_ file: CutoutFile, hints: CutoutHints?, spatial: Bool, spectral: Bool) -> CutoutSpec? {
        var region: SkyRegion?
        if spatial, file.supportsSky, let footprint = file.footprint,
           let ra = hints?.ra, let dec = hints?.dec, let r = hints?.radius, r > 0,
           SkyGeometry.overlap(SkyRegion.circle(ra: ra, dec: dec, radius: r).outline(), footprint.outline()) != .outside {
            region = circle(file, ra, dec, max(r, minimumRadius))
        }
        let band = spectral ? suggestBand(file, hints) : (nil, nil)
        let spec = CutoutSpec(artifactID: file.artifactID, region: region, bandMin: band.0, bandMax: band.1)
        return spec.isEmpty ? nil : spec
    }

    private static func suggestRegion(_ file: CutoutFile, _ hints: CutoutHints?) -> SkyRegion? {
        guard file.supportsSky, let footprint = file.footprint else { return nil }
        let reach = file.boundingCircle?.radius ?? footprint.reach
        let largest = max(minimumRadius, reach)
        func clamp(_ r: Double) -> Double { min(max(r, minimumRadius), largest) }
        if let ra = hints?.ra, let dec = hints?.dec, SkyGeometry.contains(footprint.outline(), SkyPoint(ra: ra, dec: dec)) {
            let given = hints?.radius ?? 0
            return circle(file, ra, dec, clamp(given > 0 ? given : reach / 4))
        }
        let centre = file.boundingCircle?.centre ?? footprint.centre
        return circle(file, centre.ra, centre.dec, clamp(reach / 4))
    }

    /// A circle when the file takes one; otherwise the box around it.
    private static func circle(_ file: CutoutFile, _ ra: Double, _ dec: Double, _ radius: Double) -> SkyRegion {
        file.supports("CIRCLE") ? .circle(ra: ra, dec: dec, radius: radius) : .box(ra: ra, dec: dec, width: 2 * radius, height: 2 * radius)
    }

    /// The search's band, kept to the file's own range.
    private static func suggestBand(_ file: CutoutFile, _ hints: CutoutHints?) -> (Double?, Double?) {
        guard file.supports("BAND"), let hints, hints.bandMin != nil || hints.bandMax != nil else { return (nil, nil) }
        let lo = hints.bandMin.map { a in file.bandMin.map { max(a, $0) } ?? a }
        let hi = hints.bandMax.map { b in file.bandMax.map { min(b, $0) } ?? b }
        if let lo, let hi, lo >= hi { return (nil, nil) }
        return (lo, hi)
    }
}
