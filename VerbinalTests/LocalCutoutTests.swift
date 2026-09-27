// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Cutting the downloaded file on this computer: offered beside CADC's
/// cut, preferred when it can, checked, sized exactly, and written.
@MainActor
final class LocalCutoutTests: XCTestCase {

    private var files: [URL] = []

    override func tearDown() {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func card(_ key: String, _ value: String) -> String {
        let text = key.padding(toLength: 8, withPad: " ", startingAt: 0) + "= "
            + (value.hasPrefix("'") ? value : String(repeating: " ", count: max(0, 20 - value.count)) + value)
        return text.padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    /// A 40×30 16-bit image at (150, 2), 1″ a pixel, named `name` in the
    /// temporary folder (or in `folder`, by exactly that name).
    private func image(named name: String = "G.fits", in folder: URL? = nil, crpix1: String = "20.5") throws -> URL {
        let cards = [card("SIMPLE", "T"), card("BITPIX", "16"), card("NAXIS", "2"), card("NAXIS1", "40"), card("NAXIS2", "30"),
                     card("CTYPE1", "'RA---TAN'"), card("CTYPE2", "'DEC--TAN'"), card("CRVAL1", "150.0"), card("CRVAL2", "2.0"),
                     card("CRPIX1", crpix1), card("CRPIX2", "15.5"), card("CD1_1", "-0.000277777778"), card("CD2_2", "0.000277777778"),
                     "END".padding(toLength: 80, withPad: " ", startingAt: 0)]
        var data = Data(cards.joined().utf8)
        data.append(Data(repeating: 0x20, count: 2880 - data.count % 2880))
        var pixels = Data(count: 40 * 30 * 2)
        pixels.append(Data(repeating: 0, count: 2880 - pixels.count % 2880))
        data.append(pixels)
        let url = folder?.appendingPathComponent(name)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        files.append(url)
        return url
    }

    private func soda(_ id: String) -> SodaCutoutSource {
        SodaCutoutSource(descriptor: SodaDescriptor(accessURL: "https://x/sync", artifactID: id, parameters: ["ID", "CIRCLE", "POLYGON"],
                                                    footprint: .box(ra: 150, dec: 2, width: 0.02, height: 0.02)),
                         wholeFileBytes: 1_000_000)
    }

    // MARK: - The file

    func testTheDownloadedFileIsAWayToCutNamedAsCADCNamesIt() throws {
        let url = try image(named: "G.fits")
        let renamed = url.deletingLastPathComponent().appendingPathComponent("G.fits")
        try? FileManager.default.removeItem(at: renamed)
        try FileManager.default.copyItem(at: url, to: renamed)
        files.append(renamed)
        let ways = CutoutSources.combine(local: renamed, soda: [soda("cadc:CFHTSG/G.fits")])
        XCTAssertEqual(ways.map(\.method), [.local, .soda])
        XCTAssertEqual(ways[0].file.artifactID, "cadc:CFHTSG/G.fits", "the same file, not a second one")
        XCTAssertNil(ways[0].unavailable)
        XCTAssertEqual(ways[0].file.footprint?.shape, .polygon)
        XCTAssertEqual(CutoutSources.preferred(ways)?.method, .local, "this computer first")
        XCTAssertEqual(CutoutSources.combine(local: nil, soda: [soda("x")]).map(\.method), [.soda])
    }

    func testAFileWithoutASkyIsOfferedGreyedWithWhy() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fits")
        try Data("not fits".utf8).write(to: url)
        files.append(url)
        let local = LocalCutoutSource.open(url)
        XCTAssertNotNil(local.unavailable)
        XCTAssertEqual(CutoutSources.preferred([local, soda("x")])?.method, .soda, "a way that cannot is not preferred")
    }

    // MARK: - The check, the size, the cut

    func testALocalCutIsCheckedSizedExactlyAndWritten() async throws {
        let url = try image()
        let local = LocalCutoutSource.open(url, artifactID: "cadc:X/G.fits")
        let spec = CutoutSpec(artifactID: "cadc:X/G.fits", region: .circle(ra: 150, dec: 2, radius: 2.2 / 3600), cutBy: .local)
        XCTAssertTrue(local.check(spec).isValid)
        XCTAssertEqual(local.check(CutoutSpec(artifactID: "cadc:X/G.fits", region: .circle(ra: 151, dec: 2, radius: 0.001), cutBy: .local)).errors,
                       [.outsideFootprint])
        var named = spec
        named.extensions = ["SCI,1"]
        XCTAssertEqual(local.check(named).errors, [.unknownImage("SCI,1", available: ["0"])])
        XCTAssertEqual(soda("x").check(CutoutSpec(artifactID: "x", region: .circle(ra: 150, dec: 2, radius: 0.001), extensions: ["0"])).errors,
                       [.noImageChoice], "CADC's cut keeps every image")

        let maker = LocalCutoutMaker(file: { _ in url })
        let cut = try await maker.make(publisherID: "p", spec: spec).cutout
        files.append(cut)
        XCTAssertEqual(cut.lastPathComponent, spec.fileName)
        let bytes = try Data(contentsOf: cut)
        XCTAssertEqual(Int64(bytes.count), local.estimatedBytes(spec), "the size is exact")
        XCTAssertEqual(FITSChecksum.sum(bytes), 0xFFFF_FFFF)
        let result = try FITSParser.parse(from: bytes)
        XCTAssertEqual([result.hdus[0].header.naxis1, result.hdus[0].header.naxis2], [6, 6])
    }

    func testWithNoFileHereALocalCutSaysSo() async {
        let maker = LocalCutoutMaker(file: { _ in nil })
        do {
            _ = try await maker.make(publisherID: "p", spec: CutoutSpec(artifactID: "x", region: .circle(ra: 1, dec: 1, radius: 0.1), cutBy: .local))
            XCTFail("nothing to cut")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not on this computer"), error.localizedDescription)
        }
    }

    /// A cube on this computer is cut by band too: 1.000–1.004 GHz is
    /// 0.29979–0.29860 m, and 0.2987–0.2995 m keeps channels 1…3.
    func testALocalCubeIsCutByBand() async throws {
        let url = try FITSTestFixtures.writeCube()
        files.append(url)
        let local = LocalCutoutSource.open(url)
        XCTAssertTrue(local.file.supports("BAND"))
        XCTAssertEqual(try XCTUnwrap(local.file.bandMax), 299_792_458 / 1e9, accuracy: 1e-9)
        let spec = CutoutSpec(artifactID: local.file.artifactID, region: .circle(ra: 150, dec: 2, radius: 1.5 / 3600),
                              bandMin: 0.2987, bandMax: 0.2995, cutBy: .local)
        XCTAssertTrue(local.check(spec).isValid, "\(local.check(spec).errors)")
        var off = spec
        off.bandMin = 0.5
        off.bandMax = 0.6
        XCTAssertFalse(local.check(off).isValid)

        let cut = try await LocalCutoutMaker(file: { _ in url }).make(publisherID: "p", spec: spec).cutout
        files.append(cut)
        let bytes = try Data(contentsOf: cut)
        XCTAssertEqual(Int64(bytes.count), local.estimatedBytes(spec))
        XCTAssertEqual(try FITSParser.parse(from: bytes).hdus[0].header.int("NAXIS3"), 3)
    }

    /// A weight map beside the file, on the same pixels, is cut with it and
    /// named by the same key; one on other pixels is offered greyed.
    func testAWeightMapIsCutAlongOnTheSamePixels() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("companions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        files.append(folder)
        let url = try image(named: "G.fits", in: folder)
        _ = try image(named: "G.weight.fits", in: folder)
        _ = try image(named: "G.flag.fits", in: folder, crpix1: "21.0")
        let local = LocalCutoutSource.open(url, artifactID: "cadc:X/G.fits",
                                           artifacts: ["cadc:X/G.fits", "cadc:X/G.weight.fits", "cadc:X/G.flag.fits", "cadc:X/G.cat"])
        XCTAssertEqual(local.file.companions.map(\.fileName), ["G.flag.fits", "G.weight.fits"], "FITS files beside it, not itself")
        XCTAssertNil(local.file.companions.first { $0.fileName == "G.weight.fits" }?.unavailable)
        XCTAssertNotNil(local.file.companions.first { $0.fileName == "G.flag.fits" }?.unavailable, "other pixels")

        let spec = CutoutSpec(artifactID: "cadc:X/G.fits", region: .circle(ra: 150, dec: 2, radius: 2.2 / 3600), cutBy: .local,
                              companions: ["cadc:X/G.weight.fits"])
        XCTAssertTrue(local.check(spec).isValid)
        var refused = spec
        refused.companions = ["cadc:X/G.flag.fits"]
        XCTAssertEqual(local.check(refused).errors.count, 1)

        let made = try await LocalCutoutMaker(file: { _ in url }).make(publisherID: "p", spec: spec)
        files += [made.cutout] + made.companions
        XCTAssertEqual(made.companions.map(\.lastPathComponent), ["G.weight.cutout-\(spec.key).fits"])
        let weight = try FITSParser.parse(from: Data(contentsOf: made.companions[0])).hdus[0]
        let cut = try FITSParser.parse(from: Data(contentsOf: made.cutout)).hdus[0]
        XCTAssertEqual([weight.header.naxis1, weight.header.naxis2], [cut.header.naxis1, cut.header.naxis2], "box for box")

        let asked = try args(#"{"publisherId":"p","companions":["G.weight.fits"]}"#).spec(for: local)
        XCTAssertEqual(asked.companions, ["cadc:X/G.weight.fits"], "a file name is as good as its id")
    }

    // MARK: - Choosing the way

    private func args(_ json: String) throws -> CutoutArgs {
        try JSONDecoder().decode(CutoutArgs.self, from: Data(json.utf8))
    }

    func testAnAgentGetsThisComputerUnlessItAsksForCADC() throws {
        let url = try image()
        let ways: [any CutoutSource] = [LocalCutoutSource.open(url, artifactID: "cadc:X/G.fits"), soda("cadc:X/G.fits")]
        XCTAssertEqual(try args(#"{"publisherId":"p"}"#).pickSource(ways).method, .local, "one file, two ways: this computer")
        XCTAssertEqual(try args(#"{"publisherId":"p","cutBy":"soda"}"#).pickSource(ways).method, .soda)
        XCTAssertThrowsError(try args(#"{"publisherId":"p","cutBy":"local"}"#).pickSource([soda("cadc:X/G.fits")]))
        let spec = try args(#"{"publisherId":"p","circle":{"ra":150,"dec":2,"radius":0.001},"extensions":["0"]}"#)
            .spec(for: ways[0])
        XCTAssertEqual(spec.cutBy, .local)
        XCTAssertEqual(spec.extensions, ["0"])
    }

    func testTheEditorOpensOnThisComputerAndNamesEachWay() throws {
        let url = try image()
        let editor = CutoutEditorModel(publisherID: "p", details: SaveObservationToResearchTool.record(from: .init(publisherId: "p")),
                                       sources: { ([], []) })
        editor.present(sources: [soda("cadc:X/G.fits"), LocalCutoutSource.open(url, artifactID: "cadc:X/G.fits")], problems: [])
        XCTAssertEqual(editor.source?.method, .local)
        XCTAssertTrue(editor.label(of: editor.sources[0]).hasSuffix("by CADC"))
        XCTAssertEqual(try editor.spec.get().cutBy, .local)
    }
}
