// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class ImageParserEdgeCaseTests: XCTestCase {

    func testParseSingleComponentDefaultsRegistryAndProject() {
        let raw = RawImage(id: "myimage", types: ["notebook"])
        let parsed = ImageParser.parse(raw)

        XCTAssertEqual(parsed.registry, "")
        XCTAssertEqual(parsed.project, "")
        XCTAssertEqual(parsed.name, "myimage")
        XCTAssertEqual(parsed.version, "latest")
        XCTAssertEqual(parsed.label, "myimage:latest")
    }

    func testParsePreservesOriginalId() {
        let raw = RawImage(id: "images.canfar.net/skaha/desktop:1.0", types: ["desktop"])
        let parsed = ImageParser.parse(raw)

        XCTAssertEqual(parsed.id, "images.canfar.net/skaha/desktop:1.0")
    }

    func testParseHandlesMultipleSlashes() {
        let raw = RawImage(id: "registry.io/org/sub/image:2.0", types: ["notebook"])
        let parsed = ImageParser.parse(raw)

        XCTAssertEqual(parsed.registry, "registry.io")
        XCTAssertEqual(parsed.project, "org")
        XCTAssertEqual(parsed.name, "sub/image")
        XCTAssertEqual(parsed.version, "2.0")
    }

    func testGroupByTypeAndProjectReturnsEmptyForNoImages() {
        let grouped = ImageParser.groupByTypeAndProject([])
        XCTAssertTrue(grouped.isEmpty)
    }

    func testGroupByTypeAndProjectHandlesMultipleTypes() {
        let raw = RawImage(
            id: "images.canfar.net/skaha/astroml:1.0",
            types: ["notebook", "contributed"]
        )
        let grouped = ImageParser.groupByTypeAndProject([raw])

        XCTAssertNotNil(grouped["notebook"])
        XCTAssertNotNil(grouped["contributed"])
        XCTAssertEqual(grouped["notebook"]?["skaha"]?.count, 1)
        XCTAssertEqual(grouped["contributed"]?["skaha"]?.count, 1)
    }

    func testParseRegistryWithPort() {
        let raw = RawImage(id: "host:5000/project/image:v1.2", types: ["notebook"])
        let parsed = ImageParser.parse(raw)

        XCTAssertEqual(parsed.registry, "host:5000")
        XCTAssertEqual(parsed.project, "project")
        XCTAssertEqual(parsed.name, "image")
        XCTAssertEqual(parsed.version, "v1.2")
    }
}
