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
