// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The cutout services a DataLink answer describes: one
/// `RESOURCE type="meta" utype="adhoc:service"` per file, SODA's endpoint
/// among its PARAMs and the file's own parameters — with their limits — in
/// its `inputParams` GROUP. Only the synchronous service, over https.
///
/// A descriptor that is not read is passed over with a reason: an answer
/// the parser cannot read must not look like CADC offering no cutouts
/// (Windows QA D8).
public enum SodaDescriptorParser {

    public struct Parse: Sendable, Equatable {
        public let descriptors: [SodaDescriptor]
        public let passedOver: [String]
    }

    static let syncStandard = "ivo://ivoa.net/std/soda#sync"

    public static func parse(_ data: Data) -> Parse {
        let document: XMLTreeElement
        do {
            document = try XMLTreeElement.parse(data)
        } catch {
            guard case .notWellFormed(let why) = error else { return Parse(descriptors: [], passedOver: []) }
            return Parse(descriptors: [], passedOver: ["the DataLink answer is not well-formed XML: \(why)"])
        }
        let services = ([document] + document.descendants).filter {
            $0.name == "RESOURCE" && $0.attribute("type") == "meta" && $0.attribute("utype") == "adhoc:service"
        }
        var found: [SodaDescriptor] = []
        var passedOver: [String] = []
        var others: [String] = []
        for resource in services {
            let meta = params(resource.elements("PARAM"))
            guard let standard = meta["STANDARDID"]?.attribute("value"), standard.lowercased().hasPrefix(syncStandard) else {
                // SODA's async service beside it is not a problem; named only when no sync one is there.
                others.append(meta["STANDARDID"]?.attribute("value") ?? "one naming no standardID")
                continue
            }
            switch read(resource, meta: meta) {
            case .success(let descriptor): found.append(descriptor)
            case .failure(let why): passedOver.append(why.text)
            }
        }
        if services.isEmpty {
            passedOver.append("the DataLink answer describes no service at all (no RESOURCE of type \"meta\" and utype \"adhoc:service\")")
        } else if found.isEmpty && passedOver.isEmpty {
            passedOver.append("the DataLink answer describes no SODA synchronous service, only: \(Array(Set(others)).sorted().joined(separator: ", "))")
        }
        return Parse(descriptors: found, passedOver: passedOver)
    }

    private struct Reason: Error { let text: String }

    private static func read(_ resource: XMLTreeElement, meta: [String: XMLTreeElement]) -> Result<SodaDescriptor, Reason> {
        guard let url = meta["ACCESSURL"]?.attribute("value"), !url.isEmpty else {
            return .failure(Reason(text: "the SODA service descriptor has no accessURL"))
        }
        guard url.lowercased().hasPrefix("https://") else {
            return .failure(Reason(text: "the SODA service's accessURL is not https, so it is not used: \(url)"))
        }
        guard let inputs = resource.elements("GROUP").first(where: { $0.attribute("name") == "inputParams" }) else {
            return .failure(Reason(text: "the SODA service descriptor has no inputParams group, so which file it cuts is unknown"))
        }
        let parameters = params(inputs.elements("PARAM"))
        guard let id = parameters["ID"] else {
            return .failure(Reason(text: "the SODA service descriptor has no ID parameter, so which file it cuts is unknown"))
        }
        guard let artifact = id.attribute("value")?.trimmingCharacters(in: .whitespaces), !artifact.isEmpty else {
            if let column = id.attribute("ref"), !column.isEmpty {
                return .failure(Reason(text: "the SODA service names its file by reference to the table's column \"\(column)\" rather than by value — a form this app does not read yet"))
            }
            return .failure(Reason(text: "the SODA service descriptor's ID parameter has no value, so which file it cuts is unknown"))
        }
        let circle = parameters["CIRCLE"].flatMap { circleFrom(numbers(limit($0, "MAX"))) }
        let polygon = parameters["POLYGON"].flatMap { polygonFrom(numbers(limit($0, "MAX"))) }
        let band = parameters["BAND"].map(interval) ?? (nil, nil)
        let time = parameters["TIME"].map(interval) ?? (nil, nil)
        let pol = parameters["POL"].map { $0.descendants.filter { $0.name == "OPTION" }.compactMap { $0.attribute("value") }.filter { !$0.isEmpty } } ?? []
        return .success(SodaDescriptor(
            accessURL: url, artifactID: artifact, parameters: Set(parameters.keys.filter { !$0.isEmpty }),
            footprint: polygon ?? circle, boundingCircle: circle,
            bandMin: band.0, bandMax: band.1, timeMin: time.0, timeMax: time.1, polStates: pol))
    }

    /// PARAMs by upper-case name; the first of a name wins.
    private static func params(_ elements: [XMLTreeElement]) -> [String: XMLTreeElement] {
        var byName: [String: XMLTreeElement] = [:]
        for p in elements {
            let name = (p.attribute("name") ?? "").uppercased()
            if byName[name] == nil { byName[name] = p }
        }
        return byName
    }

    /// A PARAM's MIN or MAX value, from its VALUES child.
    private static func limit(_ param: XMLTreeElement, _ which: String) -> String? {
        param.descendants.first { $0.name == which }?.attribute("value")
    }

    /// CADC gives BAND as MIN and MAX; an interval written whole into MAX ("lo hi") is read too.
    private static func interval(_ param: XMLTreeElement) -> (Double?, Double?) {
        let min = numbers(limit(param, "MIN")), max = numbers(limit(param, "MAX"))
        if max.count >= 2 && min.isEmpty { return (max[0], max[1]) }
        return (min.first, max.last)
    }

    private static func numbers(_ text: String?) -> [Double] {
        var values: [Double] = []
        for part in (text ?? "").split(whereSeparator: \.isWhitespace) {
            guard let v = Double(part), v.isFinite else { return [] }
            values.append(v)
        }
        return values
    }

    private static func circleFrom(_ n: [Double]) -> SkyRegion? {
        n.count == 3 ? .circle(ra: n[0], dec: n[1], radius: n[2]) : nil
    }

    private static func polygonFrom(_ n: [Double]) -> SkyRegion? {
        guard n.count >= 6, n.count.isMultiple(of: 2) else { return nil }
        return .polygon(stride(from: 0, to: n.count, by: 2).map { SkyPoint(ra: n[$0], dec: n[$0 + 1]) })
    }
}
