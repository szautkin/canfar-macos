// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Plan 54 A–B: every product query returns its publisher ID.
final class ADQLIdentifierTests: XCTestCase {

    private func ensure(_ adql: String, schema: TapSchema? = nil) -> ADQLIdentifier.Checked {
        ADQLIdentifier.ensure(adql, schema: schema)
    }

    // MARK: - A. The identifier, by meaning

    func testTheSchemaFindsTheIdentifierByItsUtype() {
        func col(_ name: String, _ utype: String = "") -> TapSchema.Column {
            .init(name: name, datatype: "char", description: "", unit: "", ucd: "", utype: utype)
        }
        let schema = TapSchema(tables: [
            .init(name: "my.Products", description: "", columns: [col("ra"), col("pid", "caom2:Plane.publisherID")]),
            .init(name: "my.Obs", description: "", columns: [col("uri", "caom2:Observation.uri")]),
        ])
        XCTAssertEqual(ResultIdentifier.column(of: "my.products", schema: schema), .init(name: "pid", identifies: .product))
        XCTAssertEqual(ResultIdentifier.column(of: "my.Obs", schema: schema), .init(name: "uri", identifies: .observation))
    }

    func testWithoutASchemaTheArchiveTablesAreKnown() {
        XCTAssertEqual(ResultIdentifier.column(of: "caom2.Plane", schema: nil)?.name, "publisherID")
        XCTAssertEqual(ResultIdentifier.column(of: "ivoa.ObsCore", schema: nil)?.name, "obs_publisher_did")
        XCTAssertEqual(ResultIdentifier.column(of: "caom2.SIAv1", schema: nil)?.name, "publisherDID")
        XCTAssertEqual(ResultIdentifier.column(of: "caom2.Observation", schema: nil),
                       .init(name: "observationURI", identifies: .observation))
        XCTAssertNil(ResultIdentifier.column(of: "caom2.Artifact", schema: nil))
        XCTAssertNil(ResultIdentifier.column(of: "tap_schema.tables", schema: nil))
    }

    func testResultHeadersAreRecognizedWhateverTheirSpelling() {
        for header in ["publisherID", "Publisher ID", "publisher_id", "publisherDID", "obs_publisher_did", "\"Publisher ID\""] {
            XCTAssertEqual(ResultIdentifier.of(header: header), .product, header)
        }
        XCTAssertEqual(ResultIdentifier.of(header: "Observation URI"), .observation)
        XCTAssertEqual(ResultIdentifier.of(header: "observationURI"), .observation)
        XCTAssertNil(ResultIdentifier.of(header: "Preview"))
        XCTAssertNil(ResultIdentifier.of(header: "Download"))
    }

    // MARK: - B. Every product query selects it

    func testTheFormsQueryIsUnchanged() {
        let query = ADQLBuilder.buildQuery(formState: SearchFormState(), resolverCoords: nil)
        let checked = ensure(query)
        XCTAssertEqual(checked.adql, query)
        XCTAssertNil(checked.added)
        XCTAssertEqual(checked.identifies, .product)
        XCTAssertNil(checked.gap)
    }

    func testAPlaneQueryGainsItBeforeFrom() {
        let checked = ensure("SELECT TOP 10 caom2.Plane.productID FROM caom2.Plane WHERE caom2.Plane.calibrationLevel = 2")
        XCTAssertEqual(checked.adql, "SELECT TOP 10 caom2.Plane.productID, caom2.Plane.publisherID AS \"Publisher ID\" FROM caom2.Plane WHERE caom2.Plane.calibrationLevel = 2")
        XCTAssertEqual(checked.added, "caom2.Plane.publisherID AS \"Publisher ID\"")
        XCTAssertEqual(checked.identifies, .product)
    }

    /// The person's L1, aliases and all.
    func testAnAliasedJoinGainsItThroughTheAlias() {
        let adql = """
        SELECT TOP 10 p.productID, o.collection
        FROM caom2.Plane AS p JOIN caom2.Observation AS o ON p.obsID = o.obsID
        """
        let checked = ensure(adql)
        XCTAssertEqual(checked.adql, """
        SELECT TOP 10 p.productID, o.collection, p.publisherID AS "Publisher ID"
        FROM caom2.Plane AS p JOIN caom2.Observation AS o ON p.obsID = o.obsID
        """)
        XCTAssertEqual(checked.identifies, .product, "Plane's, not Observation's")
        XCTAssertNil(checked.gap)
    }

    func testObsCoreGainsItsOwnColumn() {
        let checked = ensure("SELECT TOP 5 target_name FROM ivoa.ObsCore")
        XCTAssertEqual(checked.added, "ivoa.ObsCore.obs_publisher_did AS \"Publisher ID\"")
    }

    func testAQueryThatSelectsItAlreadyIsUnchanged() {
        for adql in [
            "SELECT * FROM caom2.Plane",
            "SELECT TOP 3 p.* FROM caom2.Plane AS p",
            "SELECT publisherID FROM caom2.Plane",
            "SELECT p.publisherID AS publisher_id FROM caom2.Plane AS p",
            "SELECT obs_publisher_did, s_ra FROM ivoa.ObsCore",
            "SELECT p.publisherID \"Publisher ID\" FROM caom2.Plane p",
        ] {
            let checked = ensure(adql)
            XCTAssertEqual(checked.adql, adql)
            XCTAssertEqual(checked.identifies, .product, adql)
        }
    }

    /// B1a: under a name the table would not recognize, it is added too.
    func testAnIdentifierUnderAnotherNameGainsTheRecognizedOne() {
        let checked = ensure("SELECT p.publisherID AS pid FROM caom2.Plane AS p")
        XCTAssertEqual(checked.adql, "SELECT p.publisherID AS pid, p.publisherID AS \"Publisher ID\" FROM caom2.Plane AS p")
    }

    func testSummariesAreLeftWithAReason() {
        for adql in [
            "SELECT DISTINCT p.collection FROM caom2.Plane AS p",
            "SELECT COUNT(*) FROM caom2.Plane",
            "SELECT p.calibrationLevel, COUNT(*) AS n FROM caom2.Plane AS p GROUP BY p.calibrationLevel",
        ] {
            let checked = ensure(adql)
            XCTAssertEqual(checked.adql, adql)
            XCTAssertNil(checked.identifies)
            XCTAssertEqual(checked.gap, .summarized, adql)
        }
    }

    /// D3: no Plane join, which would turn one row an observation into one a product.
    func testAnObservationQueryGainsItsURIAndTheJoinForProducts() {
        let checked = ensure("SELECT TOP 5 o.observationID FROM caom2.Observation AS o WHERE o.collection = 'CFHT'")
        XCTAssertEqual(checked.adql, "SELECT TOP 5 o.observationID, o.observationURI AS \"Observation URI\" FROM caom2.Observation AS o WHERE o.collection = 'CFHT'")
        XCTAssertEqual(checked.identifies, .observation)
        XCTAssertEqual(checked.gap, .observations(join: "JOIN caom2.Plane AS Plane ON Plane.obsID = o.obsID"))
    }

    func testAnArtifactQueryIsUnchangedWithTheJoin() {
        let adql = "SELECT a.uri FROM caom2.Artifact AS a"
        let checked = ensure(adql)
        XCTAssertEqual(checked.adql, adql)
        XCTAssertEqual(checked.gap, .noIdentifier(join: "JOIN caom2.Plane AS Plane ON Plane.planeID = a.planeID"))
    }

    func testTablesOutsideTheArchiveHaveNothingToSay() {
        let adql = "SELECT table_name FROM TAP_SCHEMA.tables"
        XCTAssertEqual(ensure(adql), .init(adql: adql, added: nil, identifies: nil, gap: nil))
    }

    func testCommentsQuotedNamesAndLiteralsAreNotTouched() {
        let adql = """
        SELECT TOP 2 p.productID AS "a, FROM b", 'x FROM y' AS label -- publisherID FROM here
        FROM caom2.Plane AS p
        """
        let checked = ensure(adql)
        XCTAssertEqual(checked.adql, """
        SELECT TOP 2 p.productID AS "a, FROM b", 'x FROM y' AS label, p.publisherID AS "Publisher ID" -- publisherID FROM here
        FROM caom2.Plane AS p
        """)
    }

    func testASubqueryInWhereIsReadAroundAndOneInFromIsNot() {
        let inWhere = ensure("SELECT p.productID FROM caom2.Plane AS p WHERE p.obsID IN (SELECT o.obsID FROM caom2.Observation AS o)")
        XCTAssertEqual(inWhere.added, "p.publisherID AS \"Publisher ID\"")
        let inFrom = "SELECT t.productID FROM (SELECT productID FROM caom2.Plane) AS t"
        XCTAssertEqual(ensure(inFrom).adql, inFrom)
        XCTAssertEqual(ensure(inFrom).gap, .notRead)
        let union = "SELECT publisherID FROM caom2.Plane UNION SELECT obs_publisher_did FROM ivoa.ObsCore"
        XCTAssertEqual(ensure(union).gap, .notRead)
    }

    func testFunctionsInTheSelectListAreKeptWhole() {
        let checked = ensure("SELECT COORD1(CENTROID(p.position_bounds)) AS ra, p.time_bounds_lower FROM caom2.Plane AS p")
        XCTAssertEqual(checked.adql, "SELECT COORD1(CENTROID(p.position_bounds)) AS ra, p.time_bounds_lower, p.publisherID AS \"Publisher ID\" FROM caom2.Plane AS p")
    }
}
