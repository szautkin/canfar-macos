// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// The viewer's geometry is the image's, whatever size its picture is drawn at.
@MainActor
final class FITSDisplayTests: XCTestCase {

    func testTheViewportIsSizedByTheImageNotItsPicture() async throws {
        let model = FITSViewerModel()
        FITSTestFixtures.loadRamp(into: model, width: 30, height: 20)
        model.renderParams.minCut = 0
        model.renderParams.maxCut = 600
        model.renderImage()
        for _ in 0..<200 where model.renderedImage == nil { try await Task.sleep(for: .milliseconds(5)) }
        let rendered = try XCTUnwrap(model.renderedImage)
        XCTAssertEqual([rendered.width, rendered.height], [30, 20], "under the limits, the picture is the image")
        XCTAssertEqual(model.imageSize, CGSize(width: 30, height: 20))
        XCTAssertEqual(model.displayTransform(canvasSize: CGSize(width: 300, height: 200))?.imageSize, CGSize(width: 30, height: 20))

        // New pixels, a new picture: the old one is not drawn for them.
        FITSTestFixtures.loadRamp(into: model, width: 30, height: 20)
        model.pixels = model.pixels.map { $0 * 2 }
        model.renderImage()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(model.renderedImage)
    }
}
