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

final class ImageParserTests: XCTestCase {
    func testParseExtractsRegistryProjectNameAndVersion() {
        let raw = RawImage(
            id: "images.canfar.net/skaha/desktop:1.2.3",
            types: ["desktop"]
        )

        let parsed = ImageParser.parse(raw)

        XCTAssertEqual(parsed.registry, "images.canfar.net")
        XCTAssertEqual(parsed.project, "skaha")
        XCTAssertEqual(parsed.name, "desktop")
        XCTAssertEqual(parsed.version, "1.2.3")
        XCTAssertEqual(parsed.label, "desktop:1.2.3")
    }

    func testParseDefaultsVersionToLatestWhenTagMissing() {
        let raw = RawImage(
            id: "skaha/notebook",
            types: ["notebook"]
        )

        let parsed = ImageParser.parse(raw)

        XCTAssertEqual(parsed.registry, "")
        XCTAssertEqual(parsed.project, "skaha")
        XCTAssertEqual(parsed.name, "notebook")
        XCTAssertEqual(parsed.version, "latest")
        XCTAssertEqual(parsed.label, "notebook:latest")
    }

    func testGroupByTypeAndProjectNormalizesTypesAndGroupsImages() {
        let rawImages = [
            RawImage(id: "images.canfar.net/skaha/desktop:2.0", types: ["Desktop"]),
            RawImage(id: "images.canfar.net/skaha/desktop:1.0", types: ["desktop"]),
            RawImage(id: "images.canfar.net/skaha/notebook:3.0", types: ["NOTEBOOK"])
        ]

        let grouped = ImageParser.groupByTypeAndProject(rawImages)

        XCTAssertEqual(grouped["desktop"]?["skaha"]?.map(\.label), ["desktop:2.0", "desktop:1.0"])
        XCTAssertEqual(grouped["notebook"]?["skaha"]?.map(\.label), ["notebook:3.0"])
    }
}
