// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

public enum CAOM2ParserError: Error, LocalizedError {
    case malformedXML(underlying: Error)
    case missingRoot
    case missingRequiredField(String)

    public var errorDescription: String? {
        switch self {
        case .malformedXML(let e): return "Malformed CAOM2 XML: \(e.localizedDescription)"
        case .missingRoot: return "CAOM2 document has no root element"
        case .missingRequiredField(let f): return "CAOM2 document missing required field: \(f)"
        }
    }
}

/// Tolerant CAOM-2 XML reader.
///
/// Walks the DOM rather than using XPath because the document namespaces
/// vary across schema versions (`v2.4`, `v2.5`, …) and `XMLDocument`'s
/// XPath namespace handling is fragile. Element matching uses `localName`
/// so version drift doesn't break us. Unknown elements are skipped, not
/// errored — we don't want a future schema additive change to make every
/// observation unviewable.
public enum CAOM2Parser {

    public static func parse(data: Data) throws -> CAOM2Observation {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data)
        } catch {
            throw CAOM2ParserError.malformedXML(underlying: error)
        }
        guard let root = doc.rootElement() else { throw CAOM2ParserError.missingRoot }
        return try parseObservation(root)
    }

    // MARK: - Observation

    private static func parseObservation(_ el: XMLElement) throws -> CAOM2Observation {
        guard let collection = textChild(el, "collection"), !collection.isEmpty else {
            throw CAOM2ParserError.missingRequiredField("collection")
        }
        guard let obsID = textChild(el, "observationID"), !obsID.isEmpty else {
            throw CAOM2ParserError.missingRequiredField("observationID")
        }

        return CAOM2Observation(
            collection: collection,
            observationID: obsID,
            observationType: textChild(el, "type"),
            intent: textChild(el, "intent"),
            sequenceNumber: textChild(el, "sequenceNumber"),
            metaRelease: dateChild(el, "metaRelease"),
            algorithm: textChild(child(el, "algorithm"), "name"),
            proposal: child(el, "proposal").map(parseProposal),
            target: child(el, "target").map(parseTarget),
            telescope: child(el, "telescope").map(parseTelescope),
            instrument: child(el, "instrument").map(parseInstrument),
            environment: child(el, "environment").map(parseEnvironment),
            planes: children(of: child(el, "planes"), named: "plane").map(parsePlane)
        )
    }

    // MARK: - Section parsers

    private static func parseProposal(_ el: XMLElement) -> CAOM2Observation.Proposal {
        CAOM2Observation.Proposal(
            id: textChild(el, "id"),
            pi: textChild(el, "pi"),
            project: textChild(el, "project"),
            title: textChild(el, "title"),
            keywords: keywordList(child(el, "keywords"))
        )
    }

    private static func parseTarget(_ el: XMLElement) -> CAOM2Observation.Target {
        CAOM2Observation.Target(
            name: textChild(el, "name"),
            type: textChild(el, "type"),
            standard: boolChild(el, "standard"),
            redshift: doubleChild(el, "redshift"),
            moving: boolChild(el, "moving"),
            keywords: keywordList(child(el, "keywords"))
        )
    }

    private static func parseTelescope(_ el: XMLElement) -> CAOM2Observation.Telescope {
        let x = doubleChild(el, "geoLocationX")
        let y = doubleChild(el, "geoLocationY")
        let z = doubleChild(el, "geoLocationZ")
        let geo: (Double, Double, Double)?
        if let x, let y, let z { geo = (x, y, z) } else { geo = nil }
        return CAOM2Observation.Telescope(
            name: textChild(el, "name"),
            geoLocation: geo,
            keywords: keywordList(child(el, "keywords"))
        )
    }

    private static func parseInstrument(_ el: XMLElement) -> CAOM2Observation.Instrument {
        CAOM2Observation.Instrument(
            name: textChild(el, "name"),
            keywords: keywordList(child(el, "keywords"))
        )
    }

    private static func parseEnvironment(_ el: XMLElement) -> CAOM2Observation.Environment {
        CAOM2Observation.Environment(
            seeing: doubleChild(el, "seeing"),
            humidity: doubleChild(el, "humidity"),
            elevation: doubleChild(el, "elevation"),
            tau: doubleChild(el, "tau"),
            wavelengthTau: doubleChild(el, "wavelengthTau"),
            ambientTemp: doubleChild(el, "ambientTemp"),
            photometric: boolChild(el, "photometric")
        )
    }

    private static func parsePlane(_ el: XMLElement) -> CAOM2Observation.Plane {
        CAOM2Observation.Plane(
            productID: textChild(el, "productID") ?? "",
            creatorID: textChild(el, "creatorID"),
            metaRelease: dateChild(el, "metaRelease"),
            dataRelease: dateChild(el, "dataRelease"),
            dataProductType: textChild(el, "dataProductType"),
            calibrationLevel: intChild(el, "calibrationLevel"),
            provenance: child(el, "provenance").map(parseProvenance),
            metrics: child(el, "metrics").map(parseMetrics),
            quality: textChild(child(el, "quality"), "flag"),
            position: child(el, "position").flatMap(parsePosition),
            energy: child(el, "energy").map(parseEnergy),
            time: child(el, "time").map(parseTime),
            polarization: child(el, "polarization").map(parsePolarization),
            artifacts: children(of: child(el, "artifacts"), named: "artifact").map(parseArtifact)
        )
    }

    private static func parseProvenance(_ el: XMLElement) -> CAOM2Observation.Provenance {
        let inputs: [String] = children(of: child(el, "inputs"), named: "planeURI")
            .compactMap(\.stringValue)
            .filter { !$0.isEmpty }
        return CAOM2Observation.Provenance(
            name: textChild(el, "name"),
            version: textChild(el, "version"),
            project: textChild(el, "project"),
            producer: textChild(el, "producer"),
            runID: textChild(el, "runID"),
            reference: textChild(el, "reference"),
            lastExecuted: dateChild(el, "lastExecuted"),
            keywords: keywordList(child(el, "keywords")),
            inputs: inputs
        )
    }

    private static func parseMetrics(_ el: XMLElement) -> CAOM2Observation.Metrics {
        CAOM2Observation.Metrics(
            sourceNumberDensity: doubleChild(el, "sourceNumberDensity"),
            background: doubleChild(el, "background"),
            backgroundStddev: doubleChild(el, "backgroundStddev"),
            fluxDensityLimit: doubleChild(el, "fluxDensityLimit"),
            magLimit: doubleChild(el, "magLimit"),
            sampleSNR: doubleChild(el, "sampleSNR")
        )
    }

    /// Position bounds — pulls polygon vertices when present. CAOM2 wraps
    /// the polygon under `bounds/Polygon/points/vertex/{cval1, cval2}` (via
    /// the `xsi:type="caom2:Polygon"` discriminator); only vertices with
    /// `coord` ordinal in {1, 2, …} contribute (some files include extra
    /// segment-control entries we should skip).
    private static func parsePosition(_ el: XMLElement) -> CAOM2Observation.Position? {
        var polygon: [(Double, Double)] = []
        if let bounds = child(el, "bounds") {
            // Walk to the polygon points list — name varies slightly across versions.
            let polyContainer = child(bounds, "Polygon") ?? bounds
            if let points = child(polyContainer, "points") {
                for vertexEl in children(of: points, named: "vertex") {
                    if let v = parseVertex(vertexEl) { polygon.append(v) }
                }
            }
            for vertexEl in children(of: polyContainer, named: "vertex") {
                if let v = parseVertex(vertexEl) { polygon.append(v) }
            }
        }

        let dimNAXIS1 = intChild(child(el, "dimension"), "naxis1")
        let dimNAXIS2 = intChild(child(el, "dimension"), "naxis2")
        let dim: (Int, Int)?
        if let d1 = dimNAXIS1, let d2 = dimNAXIS2 { dim = (d1, d2) } else { dim = nil }

        // Don't bother synthesising a Position if every field is empty.
        if polygon.isEmpty
            && dim == nil
            && doubleChild(el, "resolution") == nil
            && doubleChild(el, "sampleSize") == nil
            && boolChild(el, "timeDependent") == nil {
            return nil
        }

        return CAOM2Observation.Position(
            polygon: polygon.map { (ra: $0.0, dec: $0.1) },
            dimensionPixels: dim,
            resolutionArcsec: doubleChild(el, "resolution"),
            sampleSizeArcsec: doubleChild(el, "sampleSize"),
            timeDependent: boolChild(el, "timeDependent")
        )
    }

    private static func parseVertex(_ el: XMLElement) -> (Double, Double)? {
        // Vertex shapes seen in the wild:
        //  • <vertex><cval1>RA</cval1><cval2>Dec</cval2></vertex>
        //  • <vertex coord="1"><cval1>...</cval1>...</vertex>
        // Older docs have <coord1>/<coord2>. Try all.
        let ra = doubleChild(el, "cval1") ?? doubleChild(el, "coord1")
        let dec = doubleChild(el, "cval2") ?? doubleChild(el, "coord2")
        guard let ra, let dec, ra.isFinite, dec.isFinite else { return nil }
        return (ra, dec)
    }

    /// Energy bounds — TAP-style flat lower/upper. v2.x XML stores them
    /// inside `bounds/lower` and `bounds/upper`. Some older docs use
    /// `samples` / range `start.val` / `end.val` — the latter two are
    /// pulled in as a fallback when bounds are absent.
    private static func parseEnergy(_ el: XMLElement) -> CAOM2Observation.Energy {
        var lower = doubleChild(child(el, "bounds"), "lower")
        var upper = doubleChild(child(el, "bounds"), "upper")
        if lower == nil || upper == nil {
            // Fallback: range axis under `axis/range/{start,end}/val`.
            let start = doubleChild(child(child(child(el, "axis"), "range"), "start"), "val")
            let end = doubleChild(child(child(child(el, "axis"), "range"), "end"), "val")
            if lower == nil { lower = start }
            if upper == nil { upper = end }
        }
        return CAOM2Observation.Energy(
            lowerMetres: lower,
            upperMetres: upper,
            resolvingPower: doubleChild(el, "resolvingPower"),
            bandpassName: textChild(el, "bandpassName"),
            emBand: textChild(el, "emBand"),
            restWavMetres: doubleChild(el, "restwav")
        )
    }

    private static func parseTime(_ el: XMLElement) -> CAOM2Observation.Time {
        CAOM2Observation.Time(
            lowerMJD: doubleChild(child(el, "bounds"), "lower"),
            upperMJD: doubleChild(child(el, "bounds"), "upper"),
            exposureSeconds: doubleChild(el, "exposure")
        )
    }

    private static func parsePolarization(_ el: XMLElement) -> CAOM2Observation.Polarization {
        let states = children(of: child(el, "states"), named: "state")
            .compactMap(\.stringValue)
            .filter { !$0.isEmpty }
        return CAOM2Observation.Polarization(states: states)
    }

    private static func parseArtifact(_ el: XMLElement) -> CAOM2Observation.Artifact {
        let length = textChild(el, "contentLength").flatMap(Int64.init)
        return CAOM2Observation.Artifact(
            uri: textChild(el, "uri") ?? "",
            productType: textChild(el, "productType"),
            releaseType: textChild(el, "releaseType"),
            contentLength: length,
            contentType: textChild(el, "contentType"),
            contentChecksum: textChild(el, "contentChecksum")
        )
    }

    // MARK: - DOM helpers (namespace-agnostic via `localName`)

    /// First direct child element of `parent` whose local name equals `name`.
    /// Tolerates `nil` parent so call sites can chain without `if let`.
    private static func child(_ parent: XMLElement?, _ name: String) -> XMLElement? {
        guard let parent else { return nil }
        for c in parent.children ?? [] {
            if let e = c as? XMLElement, e.localName == name { return e }
        }
        return nil
    }

    /// All direct children whose local name equals `name`. Empty if `parent`
    /// is nil.
    private static func children(of parent: XMLElement?, named name: String) -> [XMLElement] {
        guard let parent else { return [] }
        return (parent.children ?? []).compactMap { node in
            (node as? XMLElement).flatMap { $0.localName == name ? $0 : nil }
        }
    }

    private static func textChild(_ parent: XMLElement?, _ name: String) -> String? {
        let value = child(parent, name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    private static func doubleChild(_ parent: XMLElement?, _ name: String) -> Double? {
        textChild(parent, name).flatMap(Double.init)
    }

    private static func intChild(_ parent: XMLElement?, _ name: String) -> Int? {
        textChild(parent, name).flatMap(Int.init)
    }

    private static func boolChild(_ parent: XMLElement?, _ name: String) -> Bool? {
        guard let s = textChild(parent, name)?.lowercased() else { return nil }
        switch s {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    /// CAOM2 dates appear in two shapes in the wild:
    ///   • plain `yyyy-MM-dd'T'HH:mm:ss(.SSS)?` with no timezone (assume UTC)
    ///   • full ISO-8601 with `Z` or `±HH:MM`
    /// Try the plain UTC form first (matches the common case in fixtures);
    /// fall back to ISO-8601 with and without fractional seconds.
    private static func dateChild(_ parent: XMLElement?, _ name: String) -> Date? {
        guard let raw = textChild(parent, name) else { return nil }
        return Self.plainUTCFractional.date(from: raw)
            ?? Self.plainUTC.date(from: raw)
            ?? Self.iso8601Fractional.date(from: raw)
            ?? Self.iso8601.date(from: raw)
    }

    private static let plainUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let plainUTCFractional: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Keyword lists are stored as `<keywords><keyword>...</keyword>...</keywords>`
    /// in some schema versions and as a single space-separated string in
    /// others. Handle both.
    private static func keywordList(_ container: XMLElement?) -> [String] {
        guard let container else { return [] }
        let elements = children(of: container, named: "keyword")
        if !elements.isEmpty {
            return elements.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let raw = container.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw.split(whereSeparator: { $0.isWhitespace || $0 == ";" })
                .map(String.init)
        }
        return []
    }
}
