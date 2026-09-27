// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// Cutouts: the sky, the regions, the SODA descriptor, the rules, the
/// request and the editor's first suggestion.
final class CutoutTests: XCTestCase {

    // MARK: - The sky

    func testGeometryOnTheSky() throws {
        XCTAssertEqual(SkyGeometry.distance(SkyPoint(ra: 0, dec: 0), SkyPoint(ra: 90, dec: 0)), 90, accuracy: 1e-9)
        XCTAssertEqual(SkyGeometry.normaliseRA(-10), 350)
        let centre = SkyPoint(ra: 359.9, dec: 60)
        for p in SkyGeometry.circleOutline(centre: centre, radius: 0.5, segments: 12) {
            XCTAssertEqual(SkyGeometry.distance(centre, p), 0.5, accuracy: 1e-9, "on the circle, across RA 0°")
        }
        let flat = try XCTUnwrap(SkyGeometry.project(SkyPoint(ra: 0.2, dec: 60.1), about: centre))
        let back = SkyGeometry.unproject(x: flat.x, y: flat.y, about: centre)
        XCTAssertEqual(back.ra, 0.2, accuracy: 1e-9)
        XCTAssertEqual(back.dec, 60.1, accuracy: 1e-9)
    }

    func testRegionsAgainstAFootprint() {
        let footprint = SkyRegion.box(ra: 10, dec: 41, width: 1, height: 1).outline()
        XCTAssertEqual(SkyGeometry.overlap(SkyRegion.circle(ra: 10, dec: 41, radius: 0.1).outline(), footprint), .inside)
        XCTAssertEqual(SkyGeometry.overlap(SkyRegion.circle(ra: 10.6, dec: 41, radius: 0.2).outline(), footprint), .partial)
        XCTAssertEqual(SkyGeometry.overlap(SkyRegion.circle(ra: 20, dec: 41, radius: 0.2).outline(), footprint), .outside)
        XCTAssertTrue(SkyGeometry.contains(footprint, SkyPoint(ra: 10.2, dec: 41.2)))
        XCTAssertEqual(SkyGeometry.overlap(SkyRegion.circle(ra: 10, dec: 41, radius: 3).outline(), footprint), .partial,
                       "a region around the whole footprint")
    }

    /// A box is a true rectangle on the sky: at Dec 60° its corners are
    /// still half a diagonal from the centre.
    func testABoxIsARectangleAtAnyDec() {
        let box = SkyRegion.box(ra: 150, dec: 60, width: 0.2, height: 0.1)
        let corners = box.outline()
        XCTAssertEqual(corners.count, 4)
        for corner in corners {
            XCTAssertEqual(SkyGeometry.distance(box.centre, corner), (0.1 * 0.1 + 0.05 * 0.05).squareRoot(), accuracy: 1e-5)
        }
        XCTAssertEqual(box.sodaParameter, "POLYGON")
        XCTAssertEqual(SkyRegion.circle(ra: 10.68, dec: 41.27, radius: 0.05).sodaValue, "10.68 41.27 0.05")
    }

    func testWhatIsWrongWithARegion() {
        XCTAssertEqual(SkyRegion.circle(ra: 10, dec: 95, radius: 1).problem, .decOutOfRange)
        XCTAssertEqual(SkyRegion.circle(ra: 10, dec: 0, radius: 0).problem, .sizeNotPositive)
        XCTAssertEqual(SkyRegion.box(ra: 10, dec: 0, width: 100, height: 1).problem, .tooLarge)
        XCTAssertEqual(SkyRegion.polygon([SkyPoint(ra: 1, dec: 1), SkyPoint(ra: 2, dec: 2)]).problem, .tooFewVertices)
        // On the equator — a great circle — three points enclose nothing.
        XCTAssertEqual(SkyRegion.polygon([SkyPoint(ra: 1, dec: 0), SkyPoint(ra: 2, dec: 0), SkyPoint(ra: 3, dec: 0)]).problem, .degenerate)
        XCTAssertNil(SkyRegion.circle(ra: 10, dec: 0, radius: 1).problem)
        XCTAssertEqual(SkyRegion.circle(ra: 10.68, dec: 41.27, radius: 2.0 / 60).summary, "r 2′ @ 10.68000°, +41.27000°")
    }

    // MARK: - The cutout

    func testACutoutIsNamedByWhatItCuts() {
        let spec = CutoutSpec(artifactID: "cadc:CFHTSG/MegaPipe.080.156.G.fits.fz", region: .circle(ra: 10, dec: 41, radius: 0.05))
        XCTAssertEqual(spec.key.count, 8)
        XCTAssertEqual(spec.key, spec.key)
        var other = spec
        other.region = .circle(ra: 10, dec: 41, radius: 0.06)
        XCTAssertNotEqual(spec.key, other.key)
        XCTAssertEqual(spec.fileName, "MegaPipe.080.156.G.cutout-\(spec.key).fits")
        XCTAssertEqual(CutoutSpec.artifactFileName("mast:HST/product/j8xa01010_drz.fits"), "j8xa01010_drz.fits")
        XCTAssertTrue(CutoutSpec(artifactID: "x").isEmpty)
        XCTAssertEqual(CutoutSpec.wavelengthRange(8.66e-4, 8.68e-4), "866–868 µm")
        XCTAssertEqual(CutoutSpec.date(mjd: 51544), "2000-01-01")
    }

    /// A cutout saved before local cuts still reads, and keeps its key.
    func testACutoutSavedBeforeLocalCutsKeepsItsKey() throws {
        let saved = #"{"artifactID":"cadc:X/a.fits","region":{"shape":"circle","ra":10,"dec":41,"radius":0.05,"width":0,"height":0,"vertices":[]},"pol":[]}"#
        let spec = try JSONDecoder().decode(CutoutSpec.self, from: Data(saved.utf8))
        XCTAssertEqual(spec.cutBy, .soda)
        XCTAssertEqual(spec.extensions, [])
        XCTAssertEqual(spec.key, CutoutSpec(artifactID: "cadc:X/a.fits", region: .circle(ra: 10, dec: 41, radius: 0.05)).key)
        var local = spec
        local.cutBy = .local
        XCTAssertNotEqual(local.key, spec.key, "a local cut is another product")
        local.extensions = ["SCI,1"]
        XCTAssertTrue(local.summary.hasSuffix("[SCI,1]"))
    }

    // MARK: - The descriptor

    private static let dataLink = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VOTABLE xmlns="http://www.ivoa.net/xml/VOTable/v1.3" version="1.3">
      <RESOURCE type="results"><TABLE><FIELD name="ID" datatype="char"/></TABLE></RESOURCE>
      <RESOURCE type="meta" utype="adhoc:service">
        <PARAM name="standardID" datatype="char" arraysize="*" value="ivo://ivoa.net/std/SODA#sync-1.0"/>
        <PARAM name="accessURL" datatype="char" arraysize="*" value="https://ws-cadc.canfar.net/caom2ops/sync"/>
        <GROUP name="inputParams">
          <PARAM name="ID" datatype="char" arraysize="*" value="cadc:CFHTSG/MegaPipe.080.156.G.fits"/>
          <PARAM name="CIRCLE" datatype="double" arraysize="3" xtype="circle" unit="deg" value="">
            <VALUES><MAX value="10.68 41.27 0.3"/></VALUES>
          </PARAM>
          <PARAM name="POLYGON" datatype="double" arraysize="*" xtype="polygon" unit="deg" value="">
            <VALUES><MAX value="10.9 41.05 10.46 41.05 10.46 41.49 10.9 41.49"/></VALUES>
          </PARAM>
          <PARAM name="BAND" datatype="double" arraysize="2" xtype="interval" unit="m" value="">
            <VALUES><MIN value="4.1e-07"/><MAX value="5.5e-07"/></VALUES>
          </PARAM>
        </GROUP>
      </RESOURCE>
      <RESOURCE type="meta" utype="adhoc:service">
        <PARAM name="standardID" value="ivo://ivoa.net/std/SODA#async-1.0"/>
        <PARAM name="accessURL" value="https://ws-cadc.canfar.net/caom2ops/async"/>
      </RESOURCE>
    </VOTABLE>
    """

    private func descriptor() throws -> SodaDescriptor {
        try XCTUnwrap(SodaDescriptorParser.parse(Data(Self.dataLink.utf8)).descriptors.first)
    }

    func testTheSyncServiceIsReadWithItsLimits() throws {
        let parse = SodaDescriptorParser.parse(Data(Self.dataLink.utf8))
        XCTAssertEqual(parse.descriptors.count, 1, "the async service is not a cutout service here")
        XCTAssertTrue(parse.passedOver.isEmpty)
        let file = try descriptor()
        XCTAssertEqual(file.accessURL, "https://ws-cadc.canfar.net/caom2ops/sync")
        XCTAssertEqual(file.artifactID, "cadc:CFHTSG/MegaPipe.080.156.G.fits")
        XCTAssertEqual(file.parameters, ["ID", "CIRCLE", "POLYGON", "BAND"])
        XCTAssertEqual(file.footprint?.shape, .polygon, "POLYGON's MAX is the footprint")
        XCTAssertEqual(file.boundingCircle?.radius, 0.3)
        XCTAssertEqual(file.bandMin, 4.1e-7)
        XCTAssertEqual(file.bandMax, 5.5e-7)
    }

    /// An answer that cannot be used says why, rather than looking like no cutouts.
    func testADescriptorPassedOverSaysWhy() {
        func why(_ xml: String) -> [String] { SodaDescriptorParser.parse(Data(xml.utf8)).passedOver }
        let http = Self.dataLink.replacingOccurrences(of: "https://ws-cadc.canfar.net/caom2ops/sync", with: "http://x/sync")
        XCTAssertTrue(why(http).first?.contains("not https") ?? false)
        let byRef = Self.dataLink.replacingOccurrences(of: #"value="cadc:CFHTSG/MegaPipe.080.156.G.fits""#, with: #"ref="dl_id" value="""#)
        XCTAssertTrue(why(byRef).first?.contains("by reference") ?? false)
        XCTAssertTrue(why("<VOTABLE><RESOURCE").first?.contains("not well-formed") ?? false)
        XCTAssertTrue(why("<VOTABLE/>").first?.contains("no service at all") ?? false)
        let asyncOnly = """
        <VOTABLE><RESOURCE type="meta" utype="adhoc:service"><PARAM name="standardID" value="ivo://ivoa.net/std/SODA#async-1.0"/></RESOURCE></VOTABLE>
        """
        XCTAssertTrue(why(asyncOnly).first?.contains("only: ivo://ivoa.net/std/SODA#async-1.0") ?? false)
    }

    // MARK: - The rules

    func testTheRulesStopWhatCannotBeCutAndSayWhatWillHappen() throws {
        let file = try descriptor()
        func check(_ spec: CutoutSpec) -> CutoutCheck { CutoutRules.check(spec, against: file) }
        XCTAssertEqual(check(CutoutSpec(artifactID: file.artifactID)).errors, [.nothingToCut])
        XCTAssertTrue(check(CutoutSpec(artifactID: file.artifactID, region: .circle(ra: 10.68, dec: 41.27, radius: 0.05))).isValid)
        XCTAssertEqual(check(CutoutSpec(artifactID: file.artifactID, region: .circle(ra: 50, dec: 41.27, radius: 0.05))).errors,
                       [.outsideFootprint])
        XCTAssertEqual(check(CutoutSpec(artifactID: file.artifactID, region: .circle(ra: 10.9, dec: 41.27, radius: 0.05))).warnings,
                       [.partlyOutsideFootprint])
        XCTAssertEqual(check(CutoutSpec(artifactID: file.artifactID, bandMin: 5e-7, bandMax: 4e-7)).errors, [.bandOrder])
        XCTAssertEqual(check(CutoutSpec(artifactID: file.artifactID, bandMin: 5e-7, bandMax: 6e-7)).warnings, [.bandPartial])
        XCTAssertEqual(check(CutoutSpec(artifactID: file.artifactID, timeMin: 1, timeMax: 2)).errors, [.noTime])
        XCTAssertEqual(check(CutoutSpec(artifactID: file.artifactID, region: .circle(ra: 10, dec: 99, radius: 1))).errors,
                       [.region(.decOutOfRange)])
    }

    // MARK: - The request

    func testTheRequestCarriesTheCutAndRefusesWhatTheRulesDo() throws {
        let file = try descriptor()
        let url = try SodaRequest.url(file, CutoutSpec(artifactID: file.artifactID,
                                                       region: .circle(ra: 10.68, dec: 41.27, radius: 0.05), bandMin: 4.5e-7))
        let text = url.absoluteString
        XCTAssertTrue(text.hasPrefix("https://ws-cadc.canfar.net/caom2ops/sync?ID=cadc%3ACFHTSG%2FMegaPipe.080.156.G.fits"), text)
        XCTAssertTrue(text.contains("&CIRCLE=10.68%2041.27%200.05"), text)
        XCTAssertTrue(text.contains("&BAND=4.5e-07%20%2BInf"), text)
        XCTAssertThrowsError(try SodaRequest.url(file, CutoutSpec(artifactID: file.artifactID)))
    }

    func testTheSizeIsEstimatedFromTheShareCut() throws {
        let file = try descriptor()
        let whole = SodaRequest.estimatedBytes(file, CutoutSpec(artifactID: file.artifactID, bandMin: 4.1e-7, bandMax: 4.8e-7),
                                               wholeFile: 1_000_000)
        XCTAssertEqual(Double(try XCTUnwrap(whole)), 500_000, accuracy: 1, "half the band")
        let small = try XCTUnwrap(SodaRequest.estimatedBytes(
            file, CutoutSpec(artifactID: file.artifactID, region: .circle(ra: 10.68, dec: 41.27, radius: 0.02)), wholeFile: 1_000_000))
        XCTAssertLessThan(small, 50_000)
        XCTAssertNil(SodaRequest.estimatedBytes(file, CutoutSpec(artifactID: file.artifactID), wholeFile: nil))
    }

    // MARK: - The first suggestion

    func testTheEditorStartsFromTheSearch() throws {
        let file = try descriptor()
        let atTarget = CutoutPrefill.suggest(file, hints: CutoutHints(ra: 10.7, dec: 41.2, radius: 0.01, bandMin: 3e-7, bandMax: 5e-7))
        XCTAssertEqual(atTarget.region, .circle(ra: 10.7, dec: 41.2, radius: 0.01))
        XCTAssertEqual(atTarget.bandMin, 4.1e-7, "kept to the file's own band")
        XCTAssertEqual(atTarget.bandMax, 5e-7)

        let elsewhere = CutoutPrefill.suggest(file, hints: CutoutHints(ra: 50, dec: 0))
        XCTAssertEqual(elsewhere.region?.centre.ra ?? 0, 10.68, accuracy: 1e-9, "the middle of the file")
        XCTAssertEqual(elsewhere.region?.radius ?? 0, 0.075, accuracy: 1e-9, "a quarter of it")
        XCTAssertTrue(CutoutRules.check(elsewhere, against: file).isValid)

        XCTAssertNil(CutoutPrefill.fromSearchFlags(file, hints: CutoutHints(ra: 50, dec: 0, radius: 0.1), spatial: true, spectral: false))
        XCTAssertEqual(CutoutPrefill.fromSearchFlags(file, hints: CutoutHints(ra: 10.7, dec: 41.2, radius: 0.1), spatial: true, spectral: false)?.region,
                       .circle(ra: 10.7, dec: 41.2, radius: 0.1))
    }
}
