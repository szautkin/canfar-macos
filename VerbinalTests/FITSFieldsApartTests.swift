// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// A linked crosshair says when a tab shows another part of the sky (plan
/// 15 V6, QA M18: a JWST GOODS-S tab linked to CFHT COSMOS tabs).
@MainActor
final class FITSFieldsApartTests: XCTestCase {

    /// A 100×100 image at 1″ per pixel centred on (ra, dec).
    private func field(_ host: FITSTabHostModel, _ name: String, ra: Double, dec: Double) -> FITSViewerModel {
        let tab = host.addTab()
        FITSTestFixtures.loadRamp(into: tab, wcsCards: [
            ("CTYPE1", "'RA---TAN'"), ("CTYPE2", "'DEC--TAN'"),
            ("CRVAL1", "\(ra)"), ("CRVAL2", "\(dec)"), ("CRPIX1", "50"), ("CRPIX2", "50"),
            ("CD1_1", "-0.000277777"), ("CD2_2", "0.000277777"),
        ], path: "/tmp/\(name).fits")
        return tab
    }

    func testATabElsewhereOnTheSkyIsNamed() throws {
        let host = FITSTabHostModel()
        let cosmos = field(host, "cosmos-a", ra: 150.1, dec: 2.2)
        _ = field(host, "cosmos-b", ra: 150.1, dec: 2.21)
        _ = field(host, "goods-s", ra: 53.16, dec: -27.78)
        host.activeTabIndex = try XCTUnwrap(host.tabs.firstIndex { $0 === cosmos })

        XCTAssertTrue(host.fieldsApartFromActive.isEmpty, "nothing to say while the crosshair is not linked")
        host.setLinkCrosshair(true)
        XCTAssertEqual(host.fieldsApartFromActive.map(\.displayName), ["goods-s.fits"])
        host.setLinkCrosshair(false)
        XCTAssertTrue(host.fieldsApartFromActive.isEmpty)
    }

    /// Plan 17 G8 (QA M18): a tab with no sky WCS is named too, not only
    /// counted as making the sync imprecise.
    func testATabWithoutASkyWCSIsNamed() throws {
        let host = FITSTabHostModel()
        _ = field(host, "cosmos-a", ra: 150.1, dec: 2.2)
        FITSTestFixtures.loadRamp(into: host.addTab(), path: "/tmp/flat.fits")
        XCTAssertTrue(host.tabsWithImpreciseWCS.isEmpty, "nothing to say while nothing is synced")
        host.linkedState.linkZoom = true
        XCTAssertEqual(host.tabsWithImpreciseWCS.map(\.displayName), ["flat.fits"])
        XCTAssertTrue(host.syncUsesImpreciseWCS)
    }

    func testTheImageCornersAreOnTheSky() throws {
        let host = FITSTabHostModel()
        let tab = field(host, "one", ra: 150.1, dec: 2.2)
        let corners = try XCTUnwrap(tab.selectedHDU?.skyCorners)
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(SkyGeometry.centroid(corners).dec, 2.2, accuracy: 0.001)
    }
}
