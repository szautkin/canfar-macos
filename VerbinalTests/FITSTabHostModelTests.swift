// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

@MainActor
final class FITSTabHostModelTests: XCTestCase {

    func testAddTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        XCTAssertEqual(host.tabCount, 1)
        XCTAssertEqual(host.activeTabIndex, 0)
    }

    func testAddMultipleTabs() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        XCTAssertEqual(host.tabCount, 2)
        XCTAssertEqual(host.activeTabIndex, 1, "New tab should be active")
    }

    func testCloseTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.closeTab(at: 0)
        XCTAssertEqual(host.tabCount, 1)
    }

    func testCloseActiveTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        host.closeActiveTab()
        XCTAssertEqual(host.tabCount, 1)
        XCTAssertEqual(host.activeTabIndex, 0)
    }

    func testCloseLastTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        host.closeTab(at: 0)
        XCTAssertEqual(host.tabCount, 0)
        XCTAssertNil(host.activeTab)
    }

    func testActiveTab() {
        let host = FITSTabHostModel()
        let tab = host.addTab()
        XCTAssertTrue(host.activeTab === tab)
    }

    func testHasMultipleTabs() {
        let host = FITSTabHostModel()
        XCTAssertFalse(host.hasMultipleTabs)
        _ = host.addTab()
        XCTAssertFalse(host.hasMultipleTabs)
        _ = host.addTab()
        XCTAssertTrue(host.hasMultipleTabs)
    }

    func testCloseOutOfBoundsNoOp() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        host.closeTab(at: 99)
        XCTAssertEqual(host.tabCount, 1, "Out-of-bounds close should be no-op")
    }

    // MARK: - syncUsesImpreciseWCS

    func testSyncWCSWarning_OffWhenNoSyncMode() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        // No sync mode active → never warns, even with WCS-less tabs.
        XCTAssertFalse(host.syncUsesImpreciseWCS)
    }

    func testSyncWCSWarning_OffWithSingleTab() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        host.linkedState.linkCrosshair = true
        // A lone tab has nothing to sync against.
        XCTAssertFalse(host.syncUsesImpreciseWCS)
    }

    func testSyncWCSWarning_OnWhenLinkedTabLacksWCS() {
        let host = FITSTabHostModel()
        _ = host.addTab()
        _ = host.addTab()
        // Empty tabs have no WCS; with a sync mode on that is imprecise.
        host.linkedState.linkCrosshair = true
        XCTAssertTrue(host.syncUsesImpreciseWCS)
        // Also fires for the zoom-sync mode.
        host.linkedState.linkCrosshair = false
        host.linkedState.linkZoom = true
        XCTAssertTrue(host.syncUsesImpreciseWCS)
    }

    func testOpenFileKeepsFailedTabForUIRetry() async throws {
        let host = FITSTabHostModel()
        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let tab = await host.openFile(url: url)
        XCTAssertEqual(host.tabCount, 1)
        XCTAssertNotNil(tab.loadError)
        XCTAssertNil(tab.file)
        XCTAssertTrue(host.activeTab === tab)
    }

    func testOpenFileDiscardingFailureRemovesDeadTab() async throws {
        let host = FITSTabHostModel()
        _ = host.addTab()
        XCTAssertEqual(host.tabCount, 1)

        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let err = await host.openFileDiscardingFailure(url: url)
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.isEmpty == false)
        XCTAssertEqual(host.tabCount, 1, "the pre-existing tab stays; the failed tab is gone")
        XCTAssertNil(host.activeTab?.loadError)
        XCTAssertNil(host.activeTab?.file)
    }

    func testOpenFileDiscardingFailureOnEmptyHostLeavesNoTab() async throws {
        let host = FITSTabHostModel()
        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let err = await host.openFileDiscardingFailure(url: url)
        XCTAssertNotNil(err)
        XCTAssertEqual(host.tabCount, 0)
        XCTAssertNil(host.activeTab)
    }

    func testOpenFileDiscardingFailureRestoresPreviouslyFocusedTab() async throws {
        // Closing the dead tab alone would land on the LAST tab; the agent
        // rollback must hand focus back to the tab the user was on.
        let host = FITSTabHostModel()
        let first = host.addTab()
        _ = host.addTab()
        host.activeTabIndex = 0

        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let err = await host.openFileDiscardingFailure(url: url)
        XCTAssertNotNil(err)
        XCTAssertEqual(host.tabCount, 2)
        XCTAssertTrue(host.activeTab === first)
    }

    func testLinkedPixelCrosshairReadsTheDrawnPixel() {
        // No WCS → pixel-only link. The value must come from the row the
        // renderer draws at that display position, not the mirrored row.
        let host = FITSTabHostModel()
        let source = host.addTab()
        let target = host.addTab()
        FITSTestFixtures.loadRamp(into: source)
        FITSTestFixtures.loadRamp(into: target)
        host.linkedState.linkCrosshair = true
        host.activeTabIndex = 0

        host.writePixelToStore(from: source, pixel: CGPoint(x: 3, y: 0))
        host.activeTabIndex = 1

        let expected = FITSTestFixtures.rampValue(x: 3, y: 99)
        XCTAssertEqual(target.crosshairValue, FITSViewerModel.formatPixelValue(expected))
    }

    // MARK: - Reopening a file

    /// Windows 1.4.0 parity: opening a file that is already open switches
    /// to its tab instead of adding a duplicate — however its path is spelled.
    func testOpeningAFileAlreadyOpenFocusesItsTab() async throws {
        let host = FITSTabHostModel()
        let path = "/tmp/ramp-\(UUID().uuidString).fits"
        let first = host.addTab()
        FITSTestFixtures.loadRamp(into: first, path: path)
        _ = host.addTab()
        XCTAssertEqual(host.activeTabIndex, 1)

        let respelled = URL(fileURLWithPath: "/tmp/./sub/../" + (path as NSString).lastPathComponent)
        let tab = await host.openFile(url: respelled)
        XCTAssertTrue(tab === first)
        XCTAssertEqual(host.tabCount, 2, "no duplicate tab")
        XCTAssertEqual(host.activeTabIndex, 0, "the existing tab is focused")
    }

    /// A tab whose open failed is not "already open": the file opens afresh.
    func testAFailedTabDoesNotBlockOpeningTheFileAgain() async throws {
        let host = FITSTabHostModel()
        let url = try FITSTestFixtures.writeNonFITSFile()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = await host.openFile(url: url)
        _ = await host.openFile(url: url)
        XCTAssertEqual(host.tabCount, 2)
    }
}

final class GetFITSWCSHDUChoiceTests: XCTestCase {

    private func hdu(_ id: Int, image: Bool, wcs: Bool) -> FITSHDUnit {
        var header = FITSHeader()
        let cards: [(String, String)] = image
            ? [("NAXIS", "2"), ("NAXIS1", "10"), ("NAXIS2", "10"), ("BITPIX", "-32")]
            : [("NAXIS", "0"), ("BITPIX", "8")]
        let wcsCards: [(String, String)] = wcs
            ? [("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"), ("CRPIX1", "5"), ("CRPIX2", "5"),
               ("CRVAL1", "10"), ("CRVAL2", "20"), ("CDELT1", "-0.001"), ("CDELT2", "0.001")]
            : []
        for (k, v) in cards + wcsCards { header.add(FITSCard(keyword: k, value: v, comment: "")) }
        return FITSHDUnit(id: id, header: header, dataOffset: 0, dataLength: image ? 400 : 0,
                          wcs: FITSWCSTransform.fromHeader(header))
    }

    /// An HST file: a primary with no image and no WCS, then SCI extensions.
    private var hst: FITSFile {
        FITSFile(url: URL(fileURLWithPath: "/tmp/hst.fits"),
                 hdus: [hdu(0, image: false, wcs: false), hdu(1, image: true, wcs: true), hdu(2, image: true, wcs: true)])
    }

    func testWithNothingOnScreenItReadsTheFirstHDUWithAWCS() throws {
        let chosen = try XCTUnwrap(GetFITSWCSTool.defaultHDU(in: hst, onScreen: nil))
        XCTAssertEqual(chosen.hdu.id, 1)
        XCTAssertEqual(chosen.chosenBy, "firstWithWCS")
    }

    func testTheHDUOnScreenWins() throws {
        let chosen = try XCTUnwrap(GetFITSWCSTool.defaultHDU(in: hst, onScreen: 2))
        XCTAssertEqual(chosen.hdu.id, 2)
        XCTAssertEqual(chosen.chosenBy, "onScreen")
    }

    func testWithoutAnyWCSItFallsBackToTheFirstImage() throws {
        let file = FITSFile(url: URL(fileURLWithPath: "/tmp/plain.fits"),
                            hdus: [hdu(0, image: false, wcs: false), hdu(1, image: true, wcs: false)])
        let chosen = try XCTUnwrap(GetFITSWCSTool.defaultHDU(in: file, onScreen: nil))
        XCTAssertEqual(chosen.hdu.id, 1)
        XCTAssertEqual(chosen.chosenBy, "firstImage")
    }
}

@MainActor
final class FITSGoToTests: XCTestCase {

    private let wcs: [(String, String)] = [
        ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"), ("CRPIX1", "50.5"), ("CRPIX2", "50.5"),
        ("CRVAL1", "10"), ("CRVAL2", "20"), ("CDELT1", "-0.001"), ("CDELT2", "0.001"),
    ]

    func testGoToOnTheImageCentres() {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model, wcsCards: wcs)
        XCTAssertEqual(model.goToCoordinate(ra: 10, dec: 20), .centred)
    }

    /// The viewer and the agent tool read the same outcome, and it says
    /// where the position falls.
    func testGoToOffTheImageSaysWhereItFalls() throws {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model, wcsCards: wcs)
        // 0.2° north of the centre: ~200 px above a 100 px image.
        guard case .offImage(let x, let y) = model.goToCoordinate(ra: 10, dec: 20.2) else {
            return XCTFail("expected off the image")
        }
        XCTAssertEqual(x, 49.5, accuracy: 1)
        XCTAssertGreaterThan(y, 99)
        let text = FITSViewerModel.whereItFalls(x: x, y: y, width: 100, height: 100)
        XCTAssertTrue(text.hasSuffix("px above the image"), text)
        XCTAssertEqual(FITSViewerModel.whereItFalls(x: -10, y: -3, width: 100, height: 100),
                       "10 px left of and 3 px below the image")
    }
}

@MainActor
final class CloseTabTests: XCTestCase {

    func testClosingByIndexClosesThatTabAndTheCubeKeepsOne() async {
        let state = AppState()
        let host = state.fitsTabHost
        _ = host.addTab(); _ = host.addTab(); _ = host.addTab()
        let tool = state.makeCloseTabTool()
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                budget: ProposalBudget(limit: 9))

        let closed = await tool.invoke(arguments: Data(#"{"kind":"fits","index":0}"#.utf8), context: ctx)
        guard case .data = closed else { return XCTFail("\(closed)") }
        XCTAssertEqual(host.tabCount, 2)

        let missing = await tool.invoke(arguments: Data(#"{"kind":"fits","index":7}"#.utf8), context: ctx)
        guard case .failed = missing else { return XCTFail("an index past the tabs must fail") }

        XCTAssertEqual(state.cubeTabHost.tabs.count, 1)
        let lastCube = await tool.invoke(arguments: Data(#"{"kind":"cube"}"#.utf8), context: ctx)
        guard case .failed(let reason) = lastCube else { return XCTFail("the last cube tab must stay") }
        XCTAssertTrue("\(reason)".contains("keeps one"))
    }
}
