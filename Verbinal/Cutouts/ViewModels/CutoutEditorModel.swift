// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// The cutout editor: one of an observation's files, the region (and
/// band) to cut from it, and what the rules say about it — checked as the
/// person types, with the size it will be. The same check an agent's
/// download_cutout is refused by.
@Observable @MainActor
final class CutoutEditorModel: Identifiable {

    enum Phase: Equatable {
        case loading
        case ready
        /// CADC can cut none of the files; why its answer offered no way to.
        case unavailable([String])
    }

    let id = UUID()
    let publisherID: String
    /// The observation, for the record the cutout is kept as.
    let details: DownloadedObservation
    private let service: CutoutService
    private let hints: CutoutHints?
    /// The cutout to open on, instead of the suggestion.
    private let initial: CutoutSpec?

    private(set) var phase: Phase = .loading
    private(set) var sources: [any CutoutSource] = []
    /// Which file; changing it starts from that file's suggestion.
    var sourceIndex = 0 {
        didSet { if oldValue != sourceIndex, let source { apply(source.suggest(hints)) } }
    }

    // The fields, as typed — a position may be sexagesimal, a number half-typed.
    var shape: SkyRegion.Shape = .circle
    var raText = ""
    var decText = ""
    var radiusArcmin = ""
    var widthArcmin = ""
    var heightArcmin = ""
    var bandMinNM = ""
    var bandMaxNM = ""
    /// A polygon an agent asked for; the editor shows it, it does not edit it.
    private(set) var polygon: SkyRegion?

    init(publisherID: String, details: DownloadedObservation, service: CutoutService,
         hints: CutoutHints? = nil, initial: CutoutSpec? = nil) {
        self.publisherID = publisherID
        self.details = details
        self.service = service
        self.hints = hints
        self.initial = initial
    }

    var source: (any CutoutSource)? { sources.indices.contains(sourceIndex) ? sources[sourceIndex] : nil }

    var takesBand: Bool { source?.file.supports("BAND") ?? false }

    // MARK: - Loading

    /// Ask CADC what the observation's files can be cut by, then open on
    /// the cutout asked for — or the suggestion from the search.
    func load() async {
        let options = await service.options(publisherID: publisherID)
        present(sources: options.sources, problems: options.problems)
    }

    /// Open on options already read (an agent's request asked CADC first).
    func present(sources: [any CutoutSource], problems: [String]) {
        self.sources = sources
        guard !sources.isEmpty else {
            phase = .unavailable(problems)
            return
        }
        let start = initial.flatMap { spec in sources.firstIndex { $0.file.artifactID == spec.artifactID }.map { ($0, spec) } }
        sourceIndex = start?.0 ?? 0
        apply(start?.1 ?? sources[sourceIndex].suggest(hints))
        phase = .ready
    }

    /// Show `spec` in the fields.
    func apply(_ spec: CutoutSpec) {
        polygon = nil
        if let region = spec.region {
            shape = region.shape
            switch region.shape {
            case .circle:
                (raText, decText, radiusArcmin) = (Self.format(region.ra), Self.format(region.dec), Self.format(region.radius * 60))
            case .box:
                (raText, decText) = (Self.format(region.ra), Self.format(region.dec))
                (widthArcmin, heightArcmin) = (Self.format(region.width * 60), Self.format(region.height * 60))
            case .polygon:
                polygon = region
            }
        }
        bandMinNM = spec.bandMin.map { Self.format($0 * 1e9) } ?? ""
        bandMaxNM = spec.bandMax.map { Self.format($0 * 1e9) } ?? ""
    }

    // MARK: - What the fields say

    /// The cutout the fields describe, or why they do not describe one yet.
    var spec: Result<CutoutSpec, FieldProblem> {
        guard let source else { return .failure(FieldProblem(text: "")) }
        let region: SkyRegion
        if shape == .polygon, let polygon {
            region = polygon
        } else {
            guard let ra = Sexagesimal.rightAscension(raText), let dec = Sexagesimal.declination(decText) else {
                return .failure(FieldProblem(text: String(localized: "Enter RA and Dec in degrees or sexagesimal")))
            }
            if shape == .box {
                guard let w = Self.number(widthArcmin), let h = Self.number(heightArcmin) else {
                    return .failure(FieldProblem(text: String(localized: "Enter the width and height in arcminutes")))
                }
                region = .box(ra: ra, dec: dec, width: w / 60, height: h / 60)
            } else {
                guard let r = Self.number(radiusArcmin) else {
                    return .failure(FieldProblem(text: String(localized: "Enter the radius in arcminutes")))
                }
                region = .circle(ra: ra, dec: dec, radius: r / 60)
            }
        }
        var bandMin: Double?, bandMax: Double?
        if takesBand {
            guard bandMinNM.isEmpty || Self.number(bandMinNM) != nil, bandMaxNM.isEmpty || Self.number(bandMaxNM) != nil else {
                return .failure(FieldProblem(text: String(localized: "Enter the wavelengths in nanometres, or leave them empty")))
            }
            bandMin = Self.number(bandMinNM).map { $0 * 1e-9 }
            bandMax = Self.number(bandMaxNM).map { $0 * 1e-9 }
        }
        return .success(CutoutSpec(artifactID: source.file.artifactID, region: region, bandMin: bandMin, bandMax: bandMax))
    }

    struct FieldProblem: Error, Equatable { let text: String }

    /// What the rules say about the cutout; nil while the fields are not numbers.
    var check: CutoutCheck? {
        guard let source, case .success(let spec) = spec else { return nil }
        return source.check(spec)
    }

    var estimatedBytes: Int64? {
        guard let source, case .success(let spec) = spec else { return nil }
        return source.estimatedBytes(spec)
    }

    /// The cutout, when the rules accept it.
    var acceptedSpec: CutoutSpec? {
        guard case .success(let spec) = spec, check?.isValid == true else { return nil }
        return spec
    }

    // MARK: - Numbers

    /// A number as typed — a decimal comma is a decimal point.
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(trimmed).flatMap { $0.isFinite ? $0 : nil }
    }

    static func format(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
