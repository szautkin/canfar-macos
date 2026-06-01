// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

public enum CAOM2ParserError: Error, LocalizedError {
    case malformedXML(underlying: Error?)
    case missingRoot
    case missingRequiredField(String)

    public var errorDescription: String? {
        switch self {
        case .malformedXML(let e):
            if let e { return "Malformed CAOM2 XML: \(e.localizedDescription)" }
            return "Malformed CAOM2 XML"
        case .missingRoot: return "CAOM2 document has no root element"
        case .missingRequiredField(let f): return "CAOM2 document missing required field: \(f)"
        }
    }
}

/// Tolerant CAOM-2 XML reader.
///
/// Builds a minimal in-memory DOM from `XMLParser` (SAX) events so the
/// same code path runs on macOS and iOS — Foundation's `XMLDocument` and
/// `XMLElement` are macOS-only. Element matching uses `localName` so the
/// document namespace prefix (`caom2:`, `vodml:`, …) doesn't matter and
/// schema-version drift across `v2.4` / `v2.5` is tolerated. Unknown
/// elements are skipped, not errored — we don't want a future schema
/// additive change to make every observation unviewable.
public enum CAOM2Parser {

    public static func parse(data: Data) throws -> CAOM2Observation {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        // shouldProcessNamespaces stays at its default (false) so element
        // names arrive prefixed (e.g. `caom2:observation`) and we strip
        // the prefix in the SAX delegate. This matches the localName
        // semantics the rest of the parser depends on.
        parser.delegate = builder
        guard parser.parse() else {
            throw CAOM2ParserError.malformedXML(underlying: parser.parserError)
        }
        guard let root = builder.root else { throw CAOM2ParserError.missingRoot }
        return try parseObservation(root)
    }

    // MARK: - Observation

    private static func parseObservation(_ el: Node) throws -> CAOM2Observation {
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

    private static func parseProposal(_ el: Node) -> CAOM2Observation.Proposal {
        CAOM2Observation.Proposal(
            id: textChild(el, "id"),
            pi: textChild(el, "pi"),
            project: textChild(el, "project"),
            title: textChild(el, "title"),
            keywords: keywordList(child(el, "keywords"))
        )
    }

    private static func parseTarget(_ el: Node) -> CAOM2Observation.Target {
        CAOM2Observation.Target(
            name: textChild(el, "name"),
            type: textChild(el, "type"),
            standard: boolChild(el, "standard"),
            redshift: doubleChild(el, "redshift"),
            moving: boolChild(el, "moving"),
            keywords: keywordList(child(el, "keywords"))
        )
    }

    private static func parseTelescope(_ el: Node) -> CAOM2Observation.Telescope {
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

    private static func parseInstrument(_ el: Node) -> CAOM2Observation.Instrument {
        CAOM2Observation.Instrument(
            name: textChild(el, "name"),
            keywords: keywordList(child(el, "keywords"))
        )
    }

    private static func parseEnvironment(_ el: Node) -> CAOM2Observation.Environment {
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

    private static func parsePlane(_ el: Node) -> CAOM2Observation.Plane {
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

    private static func parseProvenance(_ el: Node) -> CAOM2Observation.Provenance {
        let inputs: [String] = children(of: child(el, "inputs"), named: "planeURI")
            .map(\.text)
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

    private static func parseMetrics(_ el: Node) -> CAOM2Observation.Metrics {
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
    private static func parsePosition(_ el: Node) -> CAOM2Observation.Position? {
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

    private static func parseVertex(_ el: Node) -> (Double, Double)? {
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
    private static func parseEnergy(_ el: Node) -> CAOM2Observation.Energy {
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

    private static func parseTime(_ el: Node) -> CAOM2Observation.Time {
        CAOM2Observation.Time(
            lowerMJD: doubleChild(child(el, "bounds"), "lower"),
            upperMJD: doubleChild(child(el, "bounds"), "upper"),
            exposureSeconds: doubleChild(el, "exposure")
        )
    }

    private static func parsePolarization(_ el: Node) -> CAOM2Observation.Polarization {
        let states = children(of: child(el, "states"), named: "state")
            .map(\.text)
            .filter { !$0.isEmpty }
        return CAOM2Observation.Polarization(states: states)
    }

    private static func parseArtifact(_ el: Node) -> CAOM2Observation.Artifact {
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

    // MARK: - Tree helpers (namespace-agnostic via `localName`)

    /// First direct child of `parent` whose local name equals `name`.
    /// Tolerates a nil parent so call sites can chain without `if let`.
    private static func child(_ parent: Node?, _ name: String) -> Node? {
        parent?.children.first { $0.localName == name }
    }

    /// All direct children whose local name equals `name`. Empty if
    /// `parent` is nil.
    private static func children(of parent: Node?, named name: String) -> [Node] {
        (parent?.children ?? []).filter { $0.localName == name }
    }

    private static func textChild(_ parent: Node?, _ name: String) -> String? {
        let value = child(parent, name)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    private static func doubleChild(_ parent: Node?, _ name: String) -> Double? {
        textChild(parent, name).flatMap(Double.init)
    }

    private static func intChild(_ parent: Node?, _ name: String) -> Int? {
        textChild(parent, name).flatMap(Int.init)
    }

    private static func boolChild(_ parent: Node?, _ name: String) -> Bool? {
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
    private static func dateChild(_ parent: Node?, _ name: String) -> Date? {
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

    // ISO8601DateFormatter is documented thread-safe (Apple
    // formatter docs); the compiler can't infer that, so we mark
    // the statics `nonisolated(unsafe)` to silence the strict-
    // concurrency warning without locking. Used read-only after
    // the once-initialiser populates them.
    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Keyword lists are stored as `<keywords><keyword>...</keyword>...</keywords>`
    /// in some schema versions and as a single space-separated string in
    /// others. Handle both.
    private static func keywordList(_ container: Node?) -> [String] {
        guard let container else { return [] }
        let elements = children(of: container, named: "keyword")
        if !elements.isEmpty {
            return elements
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let raw = container.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            return raw.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).map(String.init)
        }
        return []
    }

    // MARK: - Minimal tree built from SAX events

    /// Direct-children only. `text` accumulates the character data that
    /// arrives while this node is on top of the parser stack — i.e. the
    /// element's *immediate* text, not the descendant string-value. CAOM2
    /// only reads leaf text, so this matches the old `XMLElement.stringValue`
    /// behavior in practice while sidestepping the surprise that property
    /// returns concatenated descendant text.
    fileprivate final class Node {
        let localName: String
        let attributes: [String: String]
        var text: String = ""
        var children: [Node] = []

        init(localName: String, attributes: [String: String]) {
            self.localName = localName
            self.attributes = attributes
        }
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                     namespaceURI: String?, qualifiedName: String?,
                     attributes attrs: [String: String]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = Node(localName: local, attributes: attrs)
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let s = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.text += s
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                     namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }
    }
}
