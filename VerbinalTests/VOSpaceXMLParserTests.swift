// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class VOSpaceXMLParserTests: XCTestCase {

    func testExtractPathFromURI() {
        let uri = "vos://cadc.nrc.ca~arc/home/testuser/folder/file.fits"
        let path = VOSpaceXMLParser.extractPath(uri)
        XCTAssertEqual(path, "folder/file.fits")
    }

    func testExtractPathRootLevel() {
        let uri = "vos://cadc.nrc.ca~arc/home/testuser"
        let path = VOSpaceXMLParser.extractPath(uri)
        XCTAssertEqual(path, "")
    }

    func testExtractPathDeep() {
        let uri = "vos://cadc.nrc.ca~arc/home/user/a/b/c/d.txt"
        let path = VOSpaceXMLParser.extractPath(uri)
        XCTAssertEqual(path, "a/b/c/d.txt")
    }

    func testBuildContainerNodeXml() {
        let xml = VOSpaceXMLParser.buildContainerNodeXml(nodeURI: "vos://cadc.nrc.ca~arc/home/user/newfolder")
        XCTAssertTrue(xml.contains("ContainerNode"))
        XCTAssertTrue(xml.contains("vos://cadc.nrc.ca~arc/home/user/newfolder"))
        XCTAssertTrue(xml.contains("xmlns:vos"))
    }

    func testBuildContainerNodeXmlEscapesSpecialChars() {
        let xml = VOSpaceXMLParser.buildContainerNodeXml(nodeURI: "vos://test&<>\"")
        XCTAssertTrue(xml.contains("&amp;"))
        XCTAssertTrue(xml.contains("&lt;"))
        XCTAssertTrue(xml.contains("&gt;"))
        XCTAssertTrue(xml.contains("&quot;"))
    }
}

final class BreadcrumbSegmentTests: XCTestCase {

    func testFromPathEmpty() {
        let segments = BreadcrumbSegment.fromPath("")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].name, "Home")
        XCTAssertEqual(segments[0].path, "")
    }

    func testFromPathSingleLevel() {
        let segments = BreadcrumbSegment.fromPath("folder")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].name, "Home")
        XCTAssertEqual(segments[1].name, "folder")
        XCTAssertEqual(segments[1].path, "folder")
    }

    func testFromPathMultipleLevels() {
        let segments = BreadcrumbSegment.fromPath("a/b/c")
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].name, "Home")
        XCTAssertEqual(segments[1].path, "a")
        XCTAssertEqual(segments[2].path, "a/b")
        XCTAssertEqual(segments[3].path, "a/b/c")
    }
}
