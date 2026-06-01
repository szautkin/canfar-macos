// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 006: `DataLinkResult.bestDirectFileURL` — the direct-file selection
/// the DownloadService DataLink (#this) fast-path relies on. Prefers an
/// uncompressed FITS, then falls back to the first direct file.
final class DataLinkBestDirectFileTests: XCTestCase {

    private func file(_ url: String, _ contentType: String, _ name: String) -> DataLinkFile {
        DataLinkFile(url: URL(string: url)!, contentType: contentType, filename: name)
    }

    func testPrefersUncompressedFITS() {
        let result = DataLinkResult(
            thumbnails: [], previews: [],
            directFiles: [
                file("https://h/a.fits.gz", "application/fits", "a.fits.gz"),  // compressed
                file("https://h/b.fits", "application/fits", "b.fits"),        // uncompressed FITS
                file("https://h/c.tar", "application/x-tar", "c.tar"),
            ]
        )
        XCTAssertEqual(result.bestDirectFileURL, URL(string: "https://h/b.fits"))
    }

    func testFallsBackToFirstWhenNoUncompressedFITS() {
        let result = DataLinkResult(
            thumbnails: [], previews: [],
            directFiles: [
                file("https://h/a.tar", "application/x-tar", "a.tar"),
                file("https://h/b.fits.gz", "application/fits", "b.fits.gz"),
            ]
        )
        XCTAssertEqual(result.bestDirectFileURL, URL(string: "https://h/a.tar"))
    }

    func testNilWhenNoDirectFiles() {
        let result = DataLinkResult(thumbnails: [], previews: [], directFiles: [])
        XCTAssertNil(result.bestDirectFileURL)
    }

    func testCompressedFITSIsNotUncompressed() {
        // .fz and .gz FITS must not be treated as uncompressed.
        XCTAssertFalse(file("https://h/x.fits.fz", "application/fits", "x.fits.fz").isUncompressedFITS)
        XCTAssertFalse(file("https://h/x.fits.gz", "application/fits", "x.fits.gz").isUncompressedFITS)
        XCTAssertTrue(file("https://h/x.fits", "application/fits", "x.fits").isUncompressedFITS)
    }
}
