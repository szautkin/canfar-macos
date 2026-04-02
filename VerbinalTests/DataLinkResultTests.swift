// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class DataLinkResultTests: XCTestCase {

    private let sampleVOTable = """
    <?xml version="1.0" encoding="UTF-8"?>
    <VOTABLE>
    <RESOURCE>
    <TABLE>
    <FIELD name="ID" datatype="char"/>
    <FIELD name="access_url" datatype="char"/>
    <FIELD name="service_def" datatype="char"/>
    <FIELD name="semantics" datatype="char"/>
    <FIELD name="description" datatype="char"/>
    <FIELD name="content_type" datatype="char"/>
    <FIELD name="content_length" datatype="long"/>
    <FIELD name="error_message" datatype="char"/>
    <FIELD name="link_authorized" datatype="boolean"/>
    <DATA><TABLEDATA>
    <TR><TD>ivo://test</TD><TD>https://example.com/thumb.jpg</TD><TD/><TD>#thumbnail</TD><TD/><TD>image/jpeg</TD><TD>1024</TD><TD/><TD>true</TD></TR>
    <TR><TD>ivo://test</TD><TD>https://example.com/preview.png</TD><TD/><TD>#preview</TD><TD/><TD>image/png</TD><TD>50000</TD><TD/><TD>true</TD></TR>
    <TR><TD>ivo://test</TD><TD>https://example.com/data.fits</TD><TD/><TD>#this</TD><TD/><TD>application/fits</TD><TD>1000000</TD><TD/><TD>true</TD></TR>
    </TABLEDATA></DATA>
    </TABLE>
    </RESOURCE>
    </VOTABLE>
    """

    func testParseVOTableWithThumbnails() {
        let result = DataLinkResult.fromVOTable(sampleVOTable)
        XCTAssertEqual(result.thumbnails.count, 1)
        XCTAssertEqual(result.thumbnails.first?.absoluteString, "https://example.com/thumb.jpg")
    }

    func testParseVOTableWithPreviews() {
        let result = DataLinkResult.fromVOTable(sampleVOTable)
        XCTAssertEqual(result.previews.count, 1)
        XCTAssertEqual(result.previews.first?.absoluteString, "https://example.com/preview.png")
    }

    func testParseVOTableIgnoresNonImagePreviews() {
        // #this with application/fits should NOT be in previews or thumbnails
        let result = DataLinkResult.fromVOTable(sampleVOTable)
        let allURLs = result.thumbnails + result.previews
        XCTAssertFalse(allURLs.contains { $0.absoluteString.contains("data.fits") })
    }

    func testParseVOTableSkipsErrors() {
        let xml = """
        <VOTABLE><RESOURCE><TABLE>
        <FIELD name="access_url" datatype="char"/>
        <FIELD name="semantics" datatype="char"/>
        <FIELD name="error_message" datatype="char"/>
        <DATA><TABLEDATA>
        <TR><TD>https://example.com/thumb.jpg</TD><TD>#thumbnail</TD><TD>NotFound</TD></TR>
        </TABLEDATA></DATA>
        </TABLE></RESOURCE></VOTABLE>
        """
        let result = DataLinkResult.fromVOTable(xml)
        XCTAssertTrue(result.isEmpty, "Rows with error_message should be skipped")
    }

    func testParseVOTableSkipsUnauthorized() {
        let xml = """
        <VOTABLE><RESOURCE><TABLE>
        <FIELD name="access_url" datatype="char"/>
        <FIELD name="semantics" datatype="char"/>
        <FIELD name="content_type" datatype="char"/>
        <FIELD name="link_authorized" datatype="boolean"/>
        <DATA><TABLEDATA>
        <TR><TD>https://example.com/thumb.jpg</TD><TD>#thumbnail</TD><TD>image/jpeg</TD><TD>false</TD></TR>
        </TABLEDATA></DATA>
        </TABLE></RESOURCE></VOTABLE>
        """
        let result = DataLinkResult.fromVOTable(xml)
        XCTAssertTrue(result.isEmpty, "Rows with link_authorized=false should be skipped")
    }

    func testParseVOTableEmpty() {
        let result = DataLinkResult.fromVOTable("<VOTABLE></VOTABLE>")
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.thumbnails.count, 0)
        XCTAssertEqual(result.previews.count, 0)
    }

    func testBestImagePrefersPreview() {
        let result = DataLinkResult.fromVOTable(sampleVOTable)
        XCTAssertEqual(result.bestImage?.absoluteString, "https://example.com/preview.png",
                       "bestImage should prefer preview over thumbnail")
    }

    func testBestImageFallsBackToThumbnail() {
        let xml = """
        <VOTABLE><RESOURCE><TABLE>
        <FIELD name="access_url" datatype="char"/>
        <FIELD name="semantics" datatype="char"/>
        <FIELD name="content_type" datatype="char"/>
        <FIELD name="link_authorized" datatype="boolean"/>
        <DATA><TABLEDATA>
        <TR><TD>https://example.com/thumb.jpg</TD><TD>#thumbnail</TD><TD>image/jpeg</TD><TD>true</TD></TR>
        </TABLEDATA></DATA>
        </TABLE></RESOURCE></VOTABLE>
        """
        let result = DataLinkResult.fromVOTable(xml)
        XCTAssertEqual(result.bestImage?.absoluteString, "https://example.com/thumb.jpg")
    }
}
