// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Cutouts in the app: kept beside their observation in Research, asked for
/// by agents, and started from the search that found the observation.
@MainActor
final class CutoutToolTests: XCTestCase {

    private var fileName = ""

    override func setUp() { fileName = "test-cutouts-\(UUID().uuidString).json" }

    override func tearDown() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Verbinal")
        if let dir { try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName)) }
    }

    /// A MegaPipe-like file: CIRCLE and POLYGON, a 0.44° box at (10.68, 41.27).
    private func file(_ id: String = "cadc:CFHTSG/MegaPipe.G.fits", band: Bool = false) -> SodaCutoutSource {
        let footprint = SkyRegion.box(ra: 10.68, dec: 41.27, width: 0.44, height: 0.44)
        return SodaCutoutSource(descriptor: SodaDescriptor(
            accessURL: "https://ws-cadc.canfar.net/caom2ops/sync", artifactID: id,
            parameters: band ? ["ID", "CIRCLE", "POLYGON", "BAND"] : ["ID", "CIRCLE", "POLYGON"],
            footprint: footprint, boundingCircle: .circle(ra: 10.68, dec: 41.27, radius: 0.31),
            bandMin: band ? 4e-7 : nil, bandMax: band ? 6e-7 : nil), wholeFileBytes: 1_600_000_000)
    }

    private func args(_ json: String) throws -> CutoutArgs {
        try JSONDecoder().decode(CutoutArgs.self, from: Data(json.utf8))
    }

    // MARK: - Research

    func testACutoutIsKeptBesideItsObservation() {
        let research = ObservationStore(fileName: fileName, spotlight: nil)
        let pid = "ivo://cadc.nrc.ca/CFHTSG?MegaPipe/G"
        let whole = research.save(DownloadedObservation(publisherID: pid, collection: "CFHTSG", observationID: "MegaPipe",
                                                        targetName: "M31", instrument: "", filter: "", ra: "", dec: "",
                                                        startDate: "", calLevel: "", localPath: "/tmp/whole.fits"))
        var cut = whole
        cut.id = UUID()
        cut.cutout = CutoutSpec(artifactID: "cadc:CFHTSG/MegaPipe.G.fits", region: .circle(ra: 10.68, dec: 41.27, radius: 0.05))
        cut.localPath = "/tmp/cut.fits"
        let first = research.save(cut)
        XCTAssertEqual(research.observations.count, 2, "not in place of the whole")
        XCTAssertNotEqual(first.id, whole.id)
        XCTAssertEqual(research.save(cut).id, first.id, "the same cutout again is the same record")
        XCTAssertEqual(research.observations.count, 2)
        XCTAssertEqual(research.whole(publisherID: pid)?.id, whole.id)
        XCTAssertEqual(research.record(identifiedBy: pid)?.id, whole.id, "a publisher id names the complete observation")

        research.remove(whole)
        XCTAssertFalse(research.contains(publisherID: pid), "a cutout is not the observation")
    }

    // MARK: - Arguments

    func testTheArgumentsReadOneRegionAndAFile() throws {
        XCTAssertEqual(try args(#"{"publisherId":"p","circle":{"ra":10,"dec":41,"radius":0.1}}"#).region(),
                       .circle(ra: 10, dec: 41, radius: 0.1))
        XCTAssertThrowsError(try args(#"{"publisherId":"p","circle":{"ra":10,"dec":41,"radius":0.1},"box":{"ra":1,"dec":2,"width":1,"height":1}}"#).region())
        XCTAssertThrowsError(try args(#"{"publisherId":"p","polygon":[[1,2],[3]]}"#).region())

        let two: [any CutoutSource] = [file("cadc:X/a.fits"), file("cadc:X/b.fits")]
        XCTAssertThrowsError(try args(#"{"publisherId":"p"}"#).pickSource(two), "which of two is not guessed")
        XCTAssertEqual(try args(#"{"publisherId":"p","artifactId":"b.fits"}"#).pickSource(two).file.artifactID, "cadc:X/b.fits",
                       "a file name is as good as its id")
        XCTAssertThrowsError(try args(#"{"publisherId":"p","artifactId":"c.fits"}"#).pickSource(two))
        XCTAssertThrowsError(try args(#"{"publisherId":"p"}"#).pickSource([]))
    }

    // MARK: - The tools

    func testTheOptionsSuggestFromTheSearchAndSayWhyWhenThereAreNone() {
        let options = CutoutOptionsOutput.from(publisherId: "p", sources: [file(band: true)],
                                               hints: CutoutHints(ra: 10.7, dec: 41.3, radius: 0.02, bandMin: 5e-7, bandMax: 9e-7),
                                               problems: [])
        let only = options.files.first
        XCTAssertEqual(only?.suggested.region, .circle(ra: 10.7, dec: 41.3, radius: 0.02))
        XCTAssertEqual(only?.suggested.bandMax, 6e-7, "kept to the file's band")
        XCTAssertEqual(only?.parameters, ["BAND", "CIRCLE", "ID", "POLYGON"])
        XCTAssertNotNil(only?.suggestedBytes)
        XCTAssertNil(options.sodaProblems)

        let none = CutoutOptionsOutput.from(publisherId: "p", sources: [], hints: nil, problems: ["the SODA service's accessURL is not https"])
        XCTAssertEqual(none.note, CutoutOptionsOutput.noneCanBeCut)
        XCTAssertEqual(none.sodaProblems, ["the SODA service's accessURL is not https"])
    }

    func testACutoutIsCheckedBeforeItIsProposed() async throws {
        let tool = DownloadCutoutTool(sources: { [file = file()] _ in [file] })
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        do {
            _ = try await tool.plan(try args(#"{"publisherId":"p","circle":{"ra":50,"dec":0,"radius":0.1}}"#), context: ctx)
            XCTFail("a region off the file")
        } catch ToolFailureReason.invalidArgument(let why) {
            XCTAssertTrue(why.contains("outside this file's footprint"), why)
        }
        let plan = try await tool.plan(try args(#"{"publisherId":" p ","circle":{"ra":10.68,"dec":41.27,"radius":0.05}}"#), context: ctx)
        let payload = try JSONDecoder().decode(DownloadCutoutTool.Payload.self, from: plan.payload)
        XCTAssertEqual(payload.publisherId, "p")
        XCTAssertEqual(payload.spec.artifactID, "cadc:CFHTSG/MegaPipe.G.fits")
        XCTAssertTrue(plan.summary.contains("r 3′ @ 10.68000°, +41.27000°"), plan.summary)
        XCTAssertTrue(plan.summary.contains("about"), "with its size")
    }

    // MARK: - The search's cutout boxes

    /// Ticked, a download is the part the search looked at; unticked, or
    /// off the file, it is the whole file.
    func testTheSearchsCutoutBoxesDecideWhatADownloadIs() {
        let hints = CutoutHints(ra: 10.7, dec: 41.3, radius: 0.02, bandMin: 5e-7, bandMax: 9e-7)
        let cube = file(band: true)
        XCTAssertNil(SearchCutout(hints: hints).spec(for: cube.file), "neither box ticked")
        XCTAssertFalse(SearchCutout(hints: nil, spatial: true).isRequested, "nothing to cut to")
        XCTAssertEqual(SearchCutout(hints: hints, spatial: true).spec(for: cube.file)?.region, .circle(ra: 10.7, dec: 41.3, radius: 0.02))
        let spectral = SearchCutout(hints: hints, spectral: true).spec(for: cube.file)
        XCTAssertNil(spectral?.region)
        XCTAssertEqual(spectral?.bandMin, 5e-7)
        XCTAssertNil(SearchCutout(hints: CutoutHints(ra: 50, dec: 0, radius: 0.1), spatial: true).spec(for: cube.file),
                     "the search's circle is not on this file")
    }

    // MARK: - The search's circle and wavelengths

    func testTheSearchSaysWhereItLookedAndWhatItAskedFor() throws {
        let typed = try XCTUnwrap(SpatialBuilder.circle(.init(target: "10.68 41.27 0.1", resolver: .none,
                                                              resolverCoords: nil, pixelScale: "")))
        XCTAssertEqual([typed.ra, typed.dec, typed.radius], [10.68, 41.27, 0.1])
        let resolved = try XCTUnwrap(SpatialBuilder.circle(.init(target: "M31", resolver: .all,
                                                                 resolverCoords: ("10.68", "41.27"), pixelScale: "")))
        XCTAssertEqual(resolved.radius, ADQL.defaultSearchRadius)
        XCTAssertNil(SpatialBuilder.circle(.init(target: "M31", resolver: .none, resolverCoords: nil, pixelScale: "")))
        let band = try XCTUnwrap(SpectralBuilder.coverageInterval("400..500nm"))
        XCTAssertEqual(try XCTUnwrap(band.min), 4e-7, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(band.max), 5e-7, accuracy: 1e-15)
    }
}
