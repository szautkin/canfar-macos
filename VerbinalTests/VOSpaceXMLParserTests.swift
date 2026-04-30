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

    /// F-14 regression: every node previously inherited the LAST
    /// `<vos:property>` of each kind from the entire document, so
    /// `sizeBytes` was constant across siblings.
    func testParseNodeListScopesPropertiesPerNode() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <vos:nodes xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.1"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <vos:node uri="vos://cadc.nrc.ca~arc/home/u/a.fits" xsi:type="vos:DataNode">
            <vos:properties>
              <vos:property uri="ivo://ivoa.net/vospace/core#length">100</vos:property>
              <vos:property uri="ivo://ivoa.net/vospace/core#type">image/fits</vos:property>
            </vos:properties>
          </vos:node>
          <vos:node uri="vos://cadc.nrc.ca~arc/home/u/b.fits" xsi:type="vos:DataNode">
            <vos:properties>
              <vos:property uri="ivo://ivoa.net/vospace/core#length">200</vos:property>
            </vos:properties>
          </vos:node>
          <vos:node uri="vos://cadc.nrc.ca~arc/home/u/c.fits" xsi:type="vos:DataNode">
            <vos:properties>
              <vos:property uri="ivo://ivoa.net/vospace/core#length">5772</vos:property>
            </vos:properties>
          </vos:node>
        </vos:nodes>
        """

        let nodes = VOSpaceXMLParser.parseNodeList(xml)

        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes[0].name, "a.fits")
        XCTAssertEqual(nodes[0].sizeBytes, 100)
        XCTAssertEqual(nodes[0].contentType, "image/fits")

        XCTAssertEqual(nodes[1].name, "b.fits")
        XCTAssertEqual(nodes[1].sizeBytes, 200)
        XCTAssertNil(nodes[1].contentType, "second node must NOT inherit first node's #type property")

        XCTAssertEqual(nodes[2].name, "c.fits")
        XCTAssertEqual(nodes[2].sizeBytes, 5772)
    }

    /// A node without any `<vos:property>` children must keep `sizeBytes`
    /// as `nil` — not default to 0, which would render as "0 bytes" in
    /// the UI and read as a real value to agents over MCP.
    func testParseNodeListLeavesSizeNilForPropertylessNode() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <vos:nodes xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.1"
                   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <vos:node uri="vos://cadc.nrc.ca~arc/home/u/empty" xsi:type="vos:ContainerNode">
            <vos:properties/>
          </vos:node>
        </vos:nodes>
        """

        let nodes = VOSpaceXMLParser.parseNodeList(xml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertNil(nodes[0].sizeBytes)
        XCTAssertNil(nodes[0].contentType)
        XCTAssertNil(nodes[0].lastModified)
        XCTAssertFalse(nodes[0].isPublic)
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
