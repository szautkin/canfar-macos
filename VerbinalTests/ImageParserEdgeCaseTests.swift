// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
