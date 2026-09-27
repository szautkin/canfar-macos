// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CryptoKit
import Foundation

/// Who cuts a file: CADC's SODA service, or this computer from the
/// complete file already downloaded.
public enum CutoutMethod: String, Codable, Sendable, CaseIterable {
    case soda, local
}

/// What a cutout cuts: which file, what part of the sky, and optionally
/// what part of the spectrum, time or polarization. Units are SODA's own —
/// metres for wavelength, MJD for time — so what is saved is what was sent.
/// A Research record with one is a cutout of its observation.
public struct CutoutSpec: Codable, Equatable, Hashable, Sendable {
    /// The file cut from, as SODA names it (e.g. `cadc:CFHTSG/….fits`) —
    /// one observation can have several.
    public var artifactID: String
    public var region: SkyRegion?
    public var bandMin: Double?
    public var bandMax: Double?
    public var timeMin: Double?
    public var timeMax: Double?
    public var pol: [String] = []
    /// Who cuts it: CADC (SODA) or this computer from the file already here.
    public var cutBy: CutoutMethod = .soda
    /// Which images of a multi-extension file a local cut keeps ("SCI,1");
    /// empty for every image the region falls on.
    public var extensions: [String] = []

    public init(artifactID: String, region: SkyRegion? = nil, bandMin: Double? = nil, bandMax: Double? = nil,
                timeMin: Double? = nil, timeMax: Double? = nil, pol: [String] = [],
                cutBy: CutoutMethod = .soda, extensions: [String] = []) {
        self.artifactID = artifactID
        self.region = region
        self.bandMin = bandMin
        self.bandMax = bandMax
        self.timeMin = timeMin
        self.timeMax = timeMax
        self.pol = pol
        self.cutBy = cutBy
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey {
        case artifactID, region, bandMin, bandMax, timeMin, timeMax, pol, cutBy, extensions
    }

    /// A cutout saved before local cuts had neither `cutBy` nor `extensions`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artifactID = try c.decode(String.self, forKey: .artifactID)
        region = try c.decodeIfPresent(SkyRegion.self, forKey: .region)
        bandMin = try c.decodeIfPresent(Double.self, forKey: .bandMin)
        bandMax = try c.decodeIfPresent(Double.self, forKey: .bandMax)
        timeMin = try c.decodeIfPresent(Double.self, forKey: .timeMin)
        timeMax = try c.decodeIfPresent(Double.self, forKey: .timeMax)
        pol = try c.decodeIfPresent([String].self, forKey: .pol) ?? []
        cutBy = try c.decodeIfPresent(CutoutMethod.self, forKey: .cutBy) ?? .soda
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? []
    }

    /// Nothing to cut: the file would come back whole.
    public var isEmpty: Bool {
        region == nil && bandMin == nil && bandMax == nil && timeMin == nil && timeMax == nil && pol.isEmpty
    }

    /// Everything that makes this cutout the one it is; `key` is its hash.
    /// A local cut is a different product from CADC's, so the method is part
    /// of it — only when local, so a SODA cutout keeps the key it had.
    public var identity: String {
        var canonical = [artifactID, region?.shape.rawValue ?? "", region?.sodaValue ?? "",
                         Self.number(bandMin), Self.number(bandMax), Self.number(timeMin), Self.number(timeMax),
                         pol.joined(separator: ",")].joined(separator: "|")
        if cutBy != .soda { canonical += "|\(cutBy.rawValue)" }
        if !extensions.isEmpty { canonical += "|ext:" + extensions.joined(separator: ";") }
        return canonical
    }

    /// Eight characters, the same for the same cutout and different for
    /// another — what tells two cutouts of one observation apart, and
    /// names the file.
    public var key: String {
        SHA256.hash(data: Data(identity.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// What it covers, in a line: "r 2′ @ 10.68000°, +41.27000° · 866–868 µm".
    public var summary: String {
        var parts: [String] = []
        if let region { parts.append(region.summary) }
        if bandMin != nil || bandMax != nil { parts.append(Self.wavelengthRange(bandMin, bandMax)) }
        if timeMin != nil || timeMax != nil { parts.append("\(Self.date(mjd: timeMin)) – \(Self.date(mjd: timeMax))") }
        if !pol.isEmpty { parts.append(pol.joined(separator: ", ")) }
        if !extensions.isEmpty { parts.append(extensions.map { "[\($0)]" }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    /// The cutout's file: the file it was cut from, marked as a cutout and
    /// by which — "G006.R.cutout-1a2b3c4d.fits". Always .fits: SODA sends
    /// plain FITS whatever compression the whole file had.
    public var fileName: String { fileName(for: Self.artifactFileName(artifactID)) }

    public func fileName(for artifactFileName: String) -> String {
        var stem = artifactFileName
        for ext in [".fz", ".gz", ".fits"] where stem.lowercased().hasSuffix(ext) {
            stem.removeLast(ext.count)
        }
        return stem.isEmpty ? "cutout-\(key).fits" : "\(stem).cutout-\(key).fits"
    }

    /// A file's own name: the last part of its artifact ID
    /// (`cadc:CFHT/2388466p.fits.fz` → `2388466p.fits.fz`).
    public static func artifactFileName(_ artifactID: String) -> String {
        let afterScheme = artifactID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? artifactID
        return afterScheme.split(separator: "/").last.map(String.init) ?? afterScheme
    }

    // MARK: - Words

    /// A wavelength range in one unit — nm, µm, mm or m — by its longer end.
    public static func wavelengthRange(_ min: Double?, _ max: Double?) -> String {
        let reference = [max, min].compactMap { $0 }.first ?? 0
        let (scale, unit): (Double, String) = reference < 1e-6 ? (1e9, "nm") : reference < 1e-3 ? (1e6, "µm")
            : reference < 1 ? (1e3, "mm") : (1, "m")
        func v(_ x: Double) -> String { String(format: "%g", x * scale) }
        switch (min, max) {
        case (let lo?, let hi?): return "\(v(lo))–\(v(hi)) \(unit)"
        case (let lo?, nil): return "> \(v(lo)) \(unit)"
        case (nil, let hi?): return "< \(v(hi)) \(unit)"
        case (nil, nil): return ""
        }
    }

    /// A Modified Julian Date as `yyyy-MM-dd` (UTC); "…" for an open end.
    public static func date(mjd: Double?) -> String {
        guard let mjd, mjd.isFinite else { return "…" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: (mjd - 40587) * 86400))
    }

    private static func number(_ v: Double?) -> String { v.map { "\($0)" } ?? "" }
}

/// A file a cutout can be cut from, and what it allows.
public protocol CutoutFile: Sendable {
    /// The file, as SODA's ID parameter names it.
    var artifactID: String { get }
    /// Upper-case names of the parameters it takes (ID, CIRCLE, POLYGON, BAND, …).
    var parameters: Set<String> { get }
    /// Its footprint on the sky, when known.
    var footprint: SkyRegion? { get }
    /// The smallest circle holding the whole file.
    var boundingCircle: SkyRegion? { get }
    /// Wavelength limits, metres.
    var bandMin: Double? { get }
    var bandMax: Double? { get }
    /// Time limits, MJD.
    var timeMin: Double? { get }
    var timeMax: Double? { get }
    /// The polarization states it lists, if any.
    var polStates: [String] { get }
    /// The images a cut can choose among, by name ("SCI,1"); empty where
    /// it cannot choose.
    var images: [String] { get }
}

extension CutoutFile {
    public var images: [String] { [] }
    public func supports(_ parameter: String) -> Bool { parameters.contains(parameter.uppercased()) }
    /// It can be cut to a region on the sky.
    public var supportsSky: Bool { supports("CIRCLE") || supports("POLYGON") }
    public var fileName: String { CutoutSpec.artifactFileName(artifactID) }
}

/// One file's cutout service, as its DataLink answer describes it: where
/// SODA is, what the file is called there, which parameters it takes, and
/// the limits of each. Per file, because files differ — a MegaPipe image
/// takes CIRCLE and POLYGON, a JCMT cube takes BAND as well.
public struct SodaDescriptor: CutoutFile, Codable, Equatable, Sendable {
    /// The SODA sync endpoint — https only.
    public var accessURL: String
    public var artifactID: String
    public var parameters: Set<String>
    /// POLYGON's MAX when given, else CIRCLE's.
    public var footprint: SkyRegion?
    /// CIRCLE's MAX.
    public var boundingCircle: SkyRegion?
    public var bandMin: Double?
    public var bandMax: Double?
    public var timeMin: Double?
    public var timeMax: Double?
    public var polStates: [String]

    public init(accessURL: String, artifactID: String, parameters: Set<String>, footprint: SkyRegion? = nil,
                boundingCircle: SkyRegion? = nil, bandMin: Double? = nil, bandMax: Double? = nil,
                timeMin: Double? = nil, timeMax: Double? = nil, polStates: [String] = []) {
        self.accessURL = accessURL
        self.artifactID = artifactID
        self.parameters = parameters
        self.footprint = footprint
        self.boundingCircle = boundingCircle
        self.bandMin = bandMin
        self.bandMax = bandMax
        self.timeMin = timeMin
        self.timeMax = timeMax
        self.polStates = polStates
    }
}
