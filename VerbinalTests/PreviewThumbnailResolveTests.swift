// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 048: `PreviewThumbnailCell.resolveThumbnailURL` swallows DataLink
/// fetch failures for graceful degradation (no error UI on a hover popover)
/// while emitting a diagnostic log. These tests pin the swallow-and-return-nil
/// contract via an injected throwing fetch double — a thrown error must leave
/// the resolved URL nil and must not propagate or crash.
final class PreviewThumbnailResolveTests: XCTestCase {

    private struct FetchError: Error {}

    func testThrownErrorResolvesToNilAndDoesNotPropagate() async {
        let url = await PreviewThumbnailCell.resolveThumbnailURL(publisherID: "ivo://test/id") {
            throw FetchError()
        }
        XCTAssertNil(url)
    }

    func testPrefersThumbnailOverPreview() async {
        let thumb = URL(string: "https://h/thumb.png")!
        let preview = URL(string: "https://h/preview.png")!
        let result = DataLinkResult(thumbnails: [thumb], previews: [preview], directFiles: [])
        let url = await PreviewThumbnailCell.resolveThumbnailURL(publisherID: "ivo://test/id") {
            result
        }
        XCTAssertEqual(url, thumb)
    }

    func testFallsBackToPreviewWhenNoThumbnail() async {
        let preview = URL(string: "https://h/preview.png")!
        let result = DataLinkResult(thumbnails: [], previews: [preview], directFiles: [])
        let url = await PreviewThumbnailCell.resolveThumbnailURL(publisherID: "ivo://test/id") {
            result
        }
        XCTAssertEqual(url, preview)
    }

    func testResolvesToNilWhenNoThumbnailOrPreview() async {
        let result = DataLinkResult(thumbnails: [], previews: [], directFiles: [])
        let url = await PreviewThumbnailCell.resolveThumbnailURL(publisherID: "ivo://test/id") {
            result
        }
        XCTAssertNil(url)
    }
}
