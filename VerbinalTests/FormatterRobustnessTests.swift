// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Covers the "raw passthrough on parse failure" and "adaptive precision"
/// contracts for every fixed-unit formatter added for CCDA parity. These are
/// the post-conditions declared on `ColumnFormatter`; tests here make them
/// enforceable at build time.
final class FormatterRobustnessTests: XCTestCase {

    // MARK: - Non-numeric passthrough

    func testFixedDurationNonNumericPassthrough() {
        for unit in [FixedDurationFormatter.Unit.seconds, .minutes, .hours, .days] {
            XCTAssertEqual(
                FixedDurationFormatter(unit: unit).format("N/A"),
                "N/A",
                "\(unit.label) should passthrough non-numeric"
            )
        }
    }

    func testFixedDurationNaNAndInfPassthrough() {
        XCTAssertEqual(FixedDurationFormatter(unit: .seconds).format("NaN"), "NaN")
        XCTAssertEqual(FixedDurationFormatter(unit: .hours).format("Infinity"), "Infinity")
    }

    func testFixedAngleNonNumericPassthrough() {
        for unit in [FixedAngleFormatter.Unit.milliarcseconds, .arcseconds, .arcminutes, .degrees] {
            XCTAssertEqual(
                FixedAngleFormatter(unit: unit).format("unknown"),
                "unknown"
            )
        }
    }

    func testFixedAngleNaNAndInfPassthrough() {
        XCTAssertEqual(FixedAngleFormatter(unit: .arcseconds).format("NaN"), "NaN")
        XCTAssertEqual(FixedAngleFormatter(unit: .degrees).format("Infinity"), "Infinity")
    }

    func testFixedAreaNonNumericPassthrough() {
        for unit in [FixedAreaFormatter.Unit.squareArcseconds, .squareArcminutes, .squareDegrees] {
            XCTAssertEqual(
                FixedAreaFormatter(unit: unit).format("—"),
                "—"
            )
        }
    }

    func testMJDRawNonNumericPassthrough() {
        XCTAssertEqual(MJDRawFormatter().format("N/A"), "N/A")
        XCTAssertEqual(MJDRawFormatter().format("NaN"), "NaN")
    }

    // MARK: - Adaptive precision (shared helper)

    func testAdaptivePrecisionBelowMilliUsesSixDecimals() {
        XCTAssertEqual(adaptivePrecisionString(0.0001), "0.000100")
        XCTAssertEqual(adaptivePrecisionString(-0.0001), "-0.000100")
    }

    func testAdaptivePrecisionAtOrAboveMilliUsesThreeDecimals() {
        XCTAssertEqual(adaptivePrecisionString(0.001), "0.001")
        // `%.3f` uses banker's rounding — 1.2345 rounds down to 1.234.
        XCTAssertEqual(adaptivePrecisionString(1.2345), "1.234")
    }

    func testAdaptivePrecisionZero() {
        XCTAssertEqual(adaptivePrecisionString(0), "0.000")
    }

    // MARK: - CellFormatterRegistry fallback paths

    func testRegistryUnknownColumnFallsThroughToRaw() {
        XCTAssertEqual(
            CellFormatterRegistry.format(id: "nonexistent_column_foo", raw: "hello"),
            "hello"
        )
    }

    func testRegistryUnknownUnitIDFallsBackToDefault() {
        // "parsecs" is not a registered unit for RA — the registry must
        // silently fall back to the column's default (HMS) rather than fail.
        let out = CellFormatterRegistry.format(id: "ra(j20000)", raw: "15", unitID: "parsecs")
        let expected = CellFormatterRegistry.format(id: "ra(j20000)", raw: "15", unitID: "hms")
        XCTAssertEqual(out, expected)
    }

    func testRegistryEmptyRawShortCircuits() {
        // Whitespace-only and empty inputs should never hit a formatter —
        // keeps format() safe to call blindly on missing cells.
        XCTAssertEqual(CellFormatterRegistry.format(id: "ra(j20000)", raw: ""), "")
        XCTAssertEqual(CellFormatterRegistry.format(id: "ra(j20000)", raw: "   "), "")
    }

    // MARK: - setUnit validation

    @MainActor
    func testSetUnitWithUnknownUnitIDIsIgnored() {
        let store = InMemoryColumnUnitStore()
        let model = SearchResultsModel(unitStore: store)
        let headers = ["\"RA (J2000.0)\""]
        let rows = [["229.638423456"]]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 10)

        // Baseline — default unit is HMS.
        XCTAssertEqual(model.selectedUnit(for: "ra(j20000)"), "hms")

        // Attempt to set an unregistered unit id.
        model.setUnit(columnID: "ra(j20000)", unitID: "parsecs")

        // Selection must not change and nothing must be persisted.
        XCTAssertEqual(model.selectedUnit(for: "ra(j20000)"), "hms")
        XCTAssertNil(store.selectedUnit(forColumnID: "ra(j20000)"))
    }

    @MainActor
    func testSetUnitOnUnknownColumnIsIgnored() {
        let store = InMemoryColumnUnitStore()
        let model = SearchResultsModel(unitStore: store)
        let headers = ["\"RA (J2000.0)\""]
        let rows = [["229.638423456"]]
        model.loadResults(headers: headers, rows: rows, query: "Q", maxRec: 10)

        model.setUnit(columnID: "totally_fake_column", unitID: "hms")
        XCTAssertNil(store.selectedUnit(forColumnID: "totally_fake_column"))
    }

    // MARK: - ColumnFormatSet unknown-unit fallback

    func testColumnFormatSetChoiceForUnknownIsNil() {
        let set = CellFormatterRegistry.sets["ra(j20000)"]!
        XCTAssertNil(set.choice(for: "parsecs"))
    }

    func testColumnFormatSetDefaultChoiceIsRegisteredDefault() {
        let set = CellFormatterRegistry.sets["ra(j20000)"]!
        XCTAssertEqual(set.defaultChoice.unitID, set.defaultUnitID)
    }
}
