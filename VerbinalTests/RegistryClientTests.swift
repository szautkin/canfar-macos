// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit

/// Parser tests for the IVOA registry documents: the `resource-caps`
/// text map and VOSI capabilities XML. Fixtures mirror the live CADC
/// responses (fetched 2026-07-03).
final class RegistryClientTests: XCTestCase {

    // MARK: - resource-caps

    func testParseResourceCapsSkipsCommentsAndBlankLines() {
        let text = """
        #
        # This file maps resource identifiers to the location of capability
        # information.
        #

        ivo://cadc.nrc.ca/argus = https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/capabilities
        ivo://cadc.nrc.ca/caom2ops = https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/caom2ops/capabilities

        ## canfar science platform
        ivo://cadc.nrc.ca/skaha = https://ws-uv.canfar.net/skaha/capabilities
        ivo://cadc.nrc.ca/arc = https://ws-uv.canfar.net/arc/capabilities
        """
        let map = RegistryClient.parseResourceCaps(text)
        XCTAssertEqual(map.count, 4)
        XCTAssertEqual(map["ivo://cadc.nrc.ca/argus"], "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/capabilities")
        XCTAssertEqual(map["ivo://cadc.nrc.ca/skaha"], "https://ws-uv.canfar.net/skaha/capabilities")
    }

    func testParseResourceCapsToleratesWhitespaceAndSkipsMalformedLines() {
        let text = """
          ivo://cadc.nrc.ca/gms   =    https://ws-cadc.canfar.net/ac/capabilities
        this line has no equals sign
        = https://orphan.example.org/capabilities
        ivo://cadc.nrc.ca/empty =
        """
        let map = RegistryClient.parseResourceCaps(text)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map["ivo://cadc.nrc.ca/gms"], "https://ws-cadc.canfar.net/ac/capabilities")
    }

    func testParseResourceCapsEmptyInput() {
        XCTAssertTrue(RegistryClient.parseResourceCaps("").isEmpty)
        XCTAssertTrue(RegistryClient.parseResourceCaps("# only comments\n").isEmpty)
    }

    // MARK: - VOSI capabilities

    private let argusStyleXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <vosi:capabilities xmlns:vosi="http://www.ivoa.net/xml/VOSICapabilities/v1.0" xmlns:vr="http://www.ivoa.net/xml/VOResource/v1.0" xmlns:vs="http://www.ivoa.net/xml/VODataService/v1.1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <capability standardID="ivo://ivoa.net/std/VOSI#capabilities">
        <interface xsi:type="vs:ParamHTTP" role="std">
          <accessURL use="full">https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/capabilities</accessURL>
        </interface>
      </capability>
      <capability standardID="ivo://ivoa.net/std/VOSI#availability">
        <interface xsi:type="vs:ParamHTTP" role="std">
          <accessURL use="full">https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/availability</accessURL>
        </interface>
      </capability>
      <capability standardID="ivo://ivoa.net/std/TAP">
        <interface xsi:type="vs:ParamHTTP" role="std" version="1.1">
          <accessURL use="base">https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus</accessURL>
        </interface>
      </capability>
    </vosi:capabilities>
    """

    func testParseCapabilitiesExtractsStandardIDsAndAccessURLs() {
        let caps = RegistryClient.parseCapabilities(Data(argusStyleXML.utf8))
        XCTAssertEqual(caps.count, 3)
        XCTAssertEqual(
            RegistryClient.accessURL(for: "ivo://ivoa.net/std/VOSI#availability", in: caps),
            "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus/availability"
        )
        XCTAssertEqual(
            RegistryClient.accessURL(for: "ivo://ivoa.net/std/TAP", in: caps),
            "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus"
        )
    }

    func testServiceRootStripsAvailabilitySuffix() {
        let caps = RegistryClient.parseCapabilities(Data(argusStyleXML.utf8))
        XCTAssertEqual(
            RegistryClient.serviceRoot(from: caps),
            "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/argus"
        )
    }

    func testServiceRootNilWithoutAvailabilityCapability() {
        let xml = """
        <capabilities>
          <capability standardID="ivo://ivoa.net/std/TAP">
            <accessURL>https://example.org/tap</accessURL>
          </capability>
        </capabilities>
        """
        let caps = RegistryClient.parseCapabilities(Data(xml.utf8))
        XCTAssertNil(RegistryClient.serviceRoot(from: caps))
    }

    func testParseCapabilitiesMalformedXMLReturnsEmpty() {
        let caps = RegistryClient.parseCapabilities(Data("this is not xml <<<".utf8))
        XCTAssertTrue(caps.isEmpty)
    }

    func testParseCapabilitiesCollectsMultipleAccessURLsPerCapability() {
        let xml = """
        <capabilities>
          <capability standardID="ivo://ivoa.net/std/VOSpace/v2.0#nodes">
            <interface><accessURL>https://ws-uv.canfar.net/arc/nodes</accessURL></interface>
            <interface><accessURL>https://mirror.example.org/arc/nodes</accessURL></interface>
          </capability>
        </capabilities>
        """
        let caps = RegistryClient.parseCapabilities(Data(xml.utf8))
        XCTAssertEqual(caps.first?.accessURLs.count, 2)
        XCTAssertEqual(
            RegistryClient.accessURL(for: "ivo://ivoa.net/std/VOSpace/v2.0#nodes", in: caps),
            "https://ws-uv.canfar.net/arc/nodes"
        )
    }
}
