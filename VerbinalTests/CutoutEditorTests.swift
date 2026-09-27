// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import CoreGraphics
import VerbinalKit
@testable import Verbinal

/// The cutout editor: what it opens on, what the fields say as they are
/// typed, and when Download is allowed.
@MainActor
final class CutoutEditorTests: XCTestCase {

    private func source(_ id: String = "cadc:CFHTSG/G.fits", band: Bool = false) -> SodaCutoutSource {
        SodaCutoutSource(descriptor: SodaDescriptor(
            accessURL: "https://ws-cadc.canfar.net/caom2ops/sync", artifactID: id,
            parameters: band ? ["ID", "CIRCLE", "POLYGON", "BAND"] : ["ID", "CIRCLE", "POLYGON"],
            footprint: .box(ra: 10.68, dec: 41.27, width: 0.44, height: 0.44),
            boundingCircle: .circle(ra: 10.68, dec: 41.27, radius: 0.31),
            bandMin: band ? 4e-7 : nil, bandMax: band ? 6e-7 : nil), wholeFileBytes: 1_600_000_000)
    }

    private func editor(hints: CutoutHints? = nil, initial: CutoutSpec? = nil,
                        sources: [any CutoutSource]? = nil) -> CutoutEditorModel {
        let model = CutoutEditorModel(
            publisherID: "ivo://cadc.nrc.ca/CFHTSG?G/G", details: SaveObservationToResearchTool.record(from: .init(publisherId: "ivo://cadc.nrc.ca/CFHTSG?G/G")),
            service: CutoutService(), hints: hints, initial: initial)
        model.present(sources: sources ?? [source()], problems: [])
        return model
    }

    func testItOpensOnTheSearchesTargetAndChecksAsYouType() throws {
        let model = editor(hints: CutoutHints(ra: 10.7, dec: 41.3, radius: 0.02))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.shape, .circle)
        XCTAssertEqual(model.raText, "10.7")
        XCTAssertEqual(model.radiusArcmin, "1.2", "0.02° in arcminutes")
        XCTAssertNotNil(model.acceptedSpec)
        XCTAssertNotNil(model.estimatedBytes)

        model.raText = "00:42:44.3"   // sexagesimal is read
        XCTAssertEqual(try model.spec.get().region?.ra ?? 0, 10.6846, accuracy: 1e-4)

        model.radiusArcmin = "1,5"   // a decimal comma
        XCTAssertEqual(try model.spec.get().region?.radius ?? 0, 0.025, accuracy: 1e-12)

        model.radiusArcmin = "abc"
        guard case .failure = model.spec else { return XCTFail("not a number") }
        XCTAssertNil(model.acceptedSpec)

        model.radiusArcmin = "1"
        model.raText = "50"
        XCTAssertEqual(model.check?.errors, [.outsideFootprint])
        XCTAssertNil(model.acceptedSpec, "Download waits for a region on the file")
    }

    func testABoxAndABandAreReadInArcminutesAndNanometres() throws {
        let model = editor(sources: [source(band: true)])
        XCTAssertTrue(model.takesBand)
        model.shape = .box
        model.raText = "10.68"
        model.decText = "41.27"
        model.widthArcmin = "3"
        model.heightArcmin = "1.5"
        model.bandMinNM = "450"
        model.bandMaxNM = ""
        let spec = try model.spec.get()
        XCTAssertEqual(spec.region, .box(ra: 10.68, dec: 41.27, width: 0.05, height: 0.025))
        XCTAssertEqual(spec.bandMin ?? 0, 4.5e-7, accuracy: 1e-18)
        XCTAssertNil(spec.bandMax, "an empty field is an open end")
    }

    func testAnotherFileStartsFromItsOwnSuggestion() {
        let model = editor(sources: [source("cadc:X/a.fits"), source("cadc:X/b.fits")])
        model.radiusArcmin = "0.5"
        model.sourceIndex = 1
        XCTAssertEqual(model.source?.file.artifactID, "cadc:X/b.fits")
        XCTAssertNotEqual(model.radiusArcmin, "0.5")
    }

    func testAnAgentsPolygonIsShownAsItIs() throws {
        let polygon = SkyRegion.polygon([SkyPoint(ra: 10.6, dec: 41.2), SkyPoint(ra: 10.8, dec: 41.2), SkyPoint(ra: 10.7, dec: 41.35)])
        let model = editor(initial: CutoutSpec(artifactID: "cadc:CFHTSG/G.fits", region: polygon))
        XCTAssertEqual(model.polygon, polygon)
        XCTAssertEqual(try model.spec.get().region, polygon)
    }

    func testNothingToCutSaysWhy() {
        let empty = CutoutEditorModel(publisherID: "p", details: SaveObservationToResearchTool.record(from: .init(publisherId: "p")),
                                      service: CutoutService())
        empty.present(sources: [], problems: ["the SODA service's accessURL is not https"])
        XCTAssertEqual(empty.phase, .unavailable(["the SODA service's accessURL is not https"]))
        XCTAssertNil(empty.acceptedSpec)
    }

    /// The sketch fits both outlines and puts east on the left, as the sky is seen.
    func testTheSketchShowsEastOnTheLeft() throws {
        let footprint = SkyRegion.box(ra: 10, dec: 0, width: 1, height: 1).outline()
        let region = SkyRegion.circle(ra: 10.3, dec: 0, radius: 0.1).outline()
        let size = CGSize(width: 100, height: 100)
        let placed = CutoutSketch.layout(footprint: footprint, region: region, in: size)
        let all = placed.footprint + placed.region
        XCTAssertTrue(all.allSatisfy { (0...100).contains($0.x) && (0...100).contains($0.y) })
        let regionX = placed.region.map(\.x).reduce(0, +) / Double(placed.region.count)
        XCTAssertLessThan(regionX, 50, "greater RA is further east, drawn to the left")
    }
}
