// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class StorageServiceTests: XCTestCase {

    private func makeService() -> StorageService {
        StorageService(network: NetworkClient(session: MockURLProtocol.mockSession()))
    }

    private func xmlResponse(_ xml: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://ws-uv.canfar.net/arc/nodes/home/testuser?limit=0")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, Data(xml.utf8))
    }

    func testGetQuotaParsesVOSpaceXML() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.1"
                  uri="vos://cadc.nrc.ca~arc/home/testuser">
            <vos:properties>
                <vos:property uri="ivo://ivoa.net/vospace/core#quota">107374182400</vos:property>
                <vos:property uri="ivo://ivoa.net/vospace/core#length">53687091200</vos:property>
                <vos:property uri="ivo://ivoa.net/vospace/core#date">2026-03-25T12:00:00.000</vos:property>
            </vos:properties>
        </vos:node>
        """

        MockURLProtocol.requestHandler = { _ in self.xmlResponse(xml) }

        let quota = try await makeService().getQuota(username: "testuser")

        XCTAssertEqual(quota.quotaBytes, 107_374_182_400)
        XCTAssertEqual(quota.usedBytes, 53_687_091_200)
        XCTAssertEqual(quota.quotaGB, 100.0, accuracy: 0.001)
        XCTAssertEqual(quota.usedGB, 50.0, accuracy: 0.001)
        XCTAssertEqual(quota.usagePercent, 50.0, accuracy: 0.001)
        XCTAssertEqual(quota.lastModified, "2026-03-25T12:00:00.000")
    }

    func testGetQuotaHandlesMissingProperties() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.1">
            <vos:properties>
            </vos:properties>
        </vos:node>
        """

        MockURLProtocol.requestHandler = { _ in self.xmlResponse(xml) }

        let quota = try await makeService().getQuota(username: "testuser")

        XCTAssertEqual(quota.quotaBytes, 0)
        XCTAssertEqual(quota.usedBytes, 0)
        XCTAssertNil(quota.lastModified)
    }
}
