// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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
