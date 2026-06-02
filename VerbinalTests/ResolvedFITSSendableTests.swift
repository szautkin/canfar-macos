// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal
@testable import VerbinalKit

/// Locks in that `ResolvedFITS` satisfies plain (auto-synthesized)
/// `Sendable` after dropping the `@unchecked` escape hatch (ticket 061).
/// The conformance test forces the compiler to verify the contract —
/// if a future field stops being `Sendable`, this file fails to build.
/// The round-trip test confirms a resolved FITS still flows through the
/// real FITS-read tool path unchanged with the conformance change in place.
final class ResolvedFITSSendableTests: XCTestCase {

    // MARK: - Fixtures

    private func ctx() -> AIToolContext {
        AIToolContext(
            origin: .external(clientID: "test"),
            proposals: InMemoryProposalStore(),
            budget: ProposalBudget(limit: 9)
        )
    }

    /// A minimal image HDU with a couple of recognizable header cards so
    /// we can assert the tool returns them verbatim.
    private func makeResolved(observationID: String) -> ResolvedFITS {
        var header = FITSHeader()
        header.add(FITSCard(keyword: "SIMPLE", value: "T", comment: "conforms to FITS"))
        header.add(FITSCard(keyword: "BITPIX", value: "-32", comment: "bits per pixel"))
        header.add(FITSCard(keyword: "NAXIS", value: "2", comment: "number of axes"))
        header.add(FITSCard(keyword: "NAXIS1", value: "4", comment: "x size"))
        header.add(FITSCard(keyword: "NAXIS2", value: "3", comment: "y size"))
        let hdu = FITSHDUnit(id: 0, header: header, dataOffset: 0, dataLength: 48, wcs: nil)
        let file = FITSFile(url: URL(fileURLWithPath: "/tmp/resolved-fits-test.fits"), hdus: [hdu])
        return ResolvedFITS(observationID: observationID, file: file)
    }

    // MARK: - Conformance (compile-time)

    /// References `ResolvedFITS` in Sendable-requiring contexts. Passing it
    /// into a `@Sendable` closure and storing it in a Sendable collection
    /// only compiles if plain `Sendable` conformance is sufficient — which
    /// is exactly what dropping `@unchecked Sendable` asserts.
    func testResolvedFITSIsSendableWithoutUncheckedEscapeHatch() async {
        let resolved = makeResolved(observationID: "obs-sendable")

        // 1. Capture in a @Sendable closure (the real tool's `resolve`
        //    closure is `@Sendable`, so this mirrors production usage).
        let produce: @Sendable () -> ResolvedFITS = { resolved }
        let captured = produce()
        XCTAssertEqual(captured.observationID, "obs-sendable")

        // 2. Cross a Task boundary (requires the captured value to be
        //    Sendable under strict concurrency checking).
        let crossed = await Task { resolved }.value
        XCTAssertEqual(crossed.observationID, "obs-sendable")

        // 3. Store in a Sendable collection.
        let collection: [ResolvedFITS] = [resolved]
        XCTAssertEqual(collection.first?.file.hdus.count, 1)

        func requireSendable<T: Sendable>(_ value: T) -> T { value }
        XCTAssertEqual(requireSendable(resolved).observationID, "obs-sendable")
    }

    // MARK: - Round-trip through the tool path

    /// Exercises `get_fits_header` end-to-end via its injected `resolve`
    /// closure and asserts the resolved FITS round-trips unchanged: the
    /// observation id and header cards come back verbatim. Guards that
    /// dropping `@unchecked Sendable` did not alter behavior.
    func testGetFITSHeaderRoundTripsResolvedFITSUnchanged() async throws {
        let resolved = makeResolved(observationID: "obs-roundtrip")
        let id = UUID()

        let tool = GetFITSHeaderTool(resolve: { @Sendable requested in
            XCTAssertEqual(requested, id)
            return resolved
        })

        let output = try await tool.handle(
            .init(downloaded_observation_id: id.uuidString, hduIndex: nil),
            context: ctx()
        )

        XCTAssertEqual(output.observationID, "obs-roundtrip")
        XCTAssertEqual(output.hduIndex, 0)
        XCTAssertEqual(output.cards.count, 5)
        XCTAssertEqual(output.cards.first?.keyword, "SIMPLE")
        XCTAssertEqual(output.cards.first?.value, "T")
        XCTAssertEqual(output.cards.first?.comment, "conforms to FITS")
        XCTAssertEqual(output.cards.map(\.keyword),
                       ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2"])
    }
}
