// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Unit coverage for the FITS-viewer parity batch (select_hdu,
/// fits_auto_cut, blink suite, set_tab_sync, search_at_crosshair,
/// export_fits_figure). Stub closures — no viewer models — except the
/// get_fits_view snapshot test, which drives AppState's registry.
final class FITSViewerParityToolsTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"),
                      proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 9))
    }

    private func argsData(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func decodeJSON(_ result: ToolResult) throws -> [String: Any] {
        guard case .data(let data) = result else {
            XCTFail("expected .data, got \(result)")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - get_fits_view (AppState snapshot)

    @MainActor
    func testGetFITSViewKeepsTabPathsAlignedAndReportsArrayCrosshair() async throws {
        let state = AppState()
        let host = state.fitsTabHost
        let loaded = host.addTab()
        FITSTestFixtures.loadRamp(into: loaded, path: "/tmp/loaded.fits")
        let failed = host.addTab()
        failed.fileURL = URL(fileURLWithPath: "/tmp/failed.fits")
        failed.loadError = "not a FITS file"
        let tool = try XCTUnwrap(state.makeAgentTools().first { $0.name == "get_fits_view" })

        // Active tab failed to load: not open, yet openTabPaths still has
        // one entry per tab so activeTabIndex / tabIndex line up.
        var json = try decodeJSON(await tool.invoke(arguments: Data("{}".utf8), context: ctx()))
        XCTAssertEqual(json["isOpen"] as? Bool, false)
        XCTAssertNil(json["filePath"] as? String)
        XCTAssertEqual(json["openTabPaths"] as? [String], ["/tmp/loaded.fits", "/tmp/failed.fits"])
        XCTAssertEqual(json["activeTabIndex"] as? Int, 1)

        // Crosshair at the canvas top-left is FITS array row naxis2-1 —
        // the pixel probe_fits_pixel(x, y) reads.
        host.activeTabIndex = 0
        loaded.placeCrosshair(at: CGPoint(x: 2, y: 0))
        json = try decodeJSON(await tool.invoke(arguments: Data("{}".utf8), context: ctx()))
        XCTAssertEqual(json["isOpen"] as? Bool, true)
        let crosshair = try XCTUnwrap(json["crosshair"] as? [String: Any])
        XCTAssertEqual(crosshair["x"] as? Int, 2)
        XCTAssertEqual(crosshair["y"] as? Int, 99)
        XCTAssertEqual(crosshair["value"] as? String, loaded.pixelValueText(atDisplay: CGPoint(x: 2, y: 0)))
    }

    // MARK: - select_hdu

    func testSelectHDUForwardsIndexAndError() async throws {
        let ok = SelectHDUTool(select: { index in
            XCTAssertEqual(index, 2); return nil
        })
        let json = try decodeJSON(await ok.invoke(
            arguments: argsData(["hduIndex": 2]), context: ctx()))
        XCTAssertEqual(json["hduIndex"] as? Int, 2)

        let failing = SelectHDUTool(select: { _ in "HDU 5 is not an image HDU" })
        let bad = await failing.invoke(arguments: argsData(["hduIndex": 5]), context: ctx())
        guard case .failed = bad else { return XCTFail("expected .failed, got \(bad)") }
    }

    // MARK: - fits_auto_cut

    func testAutoCutDistinguishesNoImageFromApplied() async throws {
        let closed = FITSAutoCutTool(autoCut: { nil })
        let failed = await closed.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed(let reason) = failed, case .targetNotResolved = reason else {
            return XCTFail("expected targetNotResolved, got \(failed)")
        }

        let open = FITSAutoCutTool(autoCut: { .init(min: 12.5, max: 980.0) })
        let json = try decodeJSON(await open.invoke(arguments: Data("{}".utf8), context: ctx()))
        XCTAssertEqual(json["minCut"] as? Double, 12.5)
        XCTAssertEqual(json["maxCut"] as? Double, 980.0)
    }

    // MARK: - blink suite

    func testStartBlinkValidatesIntervalAndMapsResults() async throws {
        let tool = StartBlinkTool(start: { args in
            XCTAssertEqual(args.tabA, 0)
            XCTAssertEqual(args.tabB, 1)
            return .started(.init(tabA: 0, tabB: 1, alignedWithWCS: true))
        })
        let json = try decodeJSON(await tool.invoke(
            arguments: argsData(["tabA": 0, "tabB": 1]), context: ctx()))
        XCTAssertEqual(json["alignedWithWCS"] as? Bool, true)

        let badInterval = await tool.invoke(
            arguments: argsData(["intervalSeconds": 9]), context: ctx())
        guard case .failed = badInterval else {
            return XCTFail("expected .failed for interval out of range")
        }

        let rejected = StartBlinkTool(start: { _ in .rejected("Blink needs at least 2 open FITS tabs") })
        let result = await rejected.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed = result else { return XCTFail("expected .failed, got \(result)") }
    }

    func testSetBlinkRejectsNoOpAndBadShow() async {
        let tool = SetBlinkTool(apply: { _ in nil })
        let noop = await tool.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed = noop else { return XCTFail("expected .failed for no-op") }
        let badShow = await tool.invoke(arguments: argsData(["show": "c"]), context: ctx())
        guard case .failed = badShow else { return XCTFail("expected .failed for show=c") }
    }

    func testStopBlinkSurfacesNotRunning() async {
        let tool = StopBlinkTool(stop: { "No blink session is running" })
        let result = await tool.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed = result else { return XCTFail("expected .failed, got \(result)") }
    }

    // MARK: - set_tab_sync

    func testSetTabSyncRequiresAtLeastOneFlagAndEchoesState() async throws {
        let tool = SetTabSyncTool(apply: { args in
            XCTAssertEqual(args.linkCrosshair, true)
            return .applied(.init(linkCrosshair: true, syncZoom: false, usesImpreciseWCS: true))
        })
        let noop = await tool.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed = noop else { return XCTFail("expected .failed for no flags") }

        let json = try decodeJSON(await tool.invoke(
            arguments: argsData(["linkCrosshair": true]), context: ctx()))
        XCTAssertEqual(json["linkCrosshair"] as? Bool, true)
        XCTAssertEqual(json["usesImpreciseWCS"] as? Bool, true)
    }

    // MARK: - search_at_crosshair

    func testSearchAtCrosshairMapsRejectionAndCoordinates() async throws {
        let noCrosshair = SearchAtCrosshairTool(run: { .rejected("No crosshair") })
        let failed = await noCrosshair.invoke(arguments: Data("{}".utf8), context: ctx())
        guard case .failed(let reason) = failed, case .targetNotResolved = reason else {
            return XCTFail("expected targetNotResolved, got \(failed)")
        }

        let ok = SearchAtCrosshairTool(run: { .applied(raDeg: 10.68, decDeg: 41.27) })
        let json = try decodeJSON(await ok.invoke(arguments: Data("{}".utf8), context: ctx()))
        XCTAssertEqual(json["raDeg"] as? Double, 10.68)
    }

    // MARK: - export_fits_figure

    func testExportFITSFigurePlanValidatesScale() async throws {
        let tool = ExportFITSFigureTool()
        do {
            _ = try await tool.plan(.init(scale: 7), context: ctx())
            XCTFail("expected invalidArgument for scale 7")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        }
        let plan = try await tool.plan(.init(scale: nil), context: ctx())
        XCTAssertEqual(plan.kind, "export_fits_figure")
        let payload = try JSONDecoder().decode(ExportFITSFigureTool.Payload.self, from: plan.payload)
        XCTAssertEqual(payload.scale, 2)
    }
}
