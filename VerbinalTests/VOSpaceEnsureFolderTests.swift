// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 36 2.9 (QA P2-1): a folder is asked for before it is made, and one
/// already there is not made again — no 409s, no failed changes.
final class VOSpaceEnsureFolderTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testOnlyTheMissingFoldersAreMadeParentsFirst() async throws {
        var asked: [String] = []
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let path = url.path.components(separatedBy: "/me/").last ?? url.path
            asked.append("\(request.httpMethod ?? "") \(path)")
            let status = request.httpMethod == "GET" && path != ".verbinal" ? 404 : (request.httpMethod == "PUT" ? 201 : 200)
            let body = status == 200 ? Data("""
                <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
                uri="vos://cadc.nrc.ca~arc/home/me/.verbinal" xsi:type="vos:ContainerNode"><vos:properties/></vos:node>
                """.utf8) : Data()
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
        let service = VOSpaceBrowserService(network: NetworkClient(session: MockURLProtocol.mockSession()))
        try await service.ensureFolder(username: "me", path: ".verbinal/exec/inbox")
        XCTAssertEqual(asked, ["GET .verbinal", "GET .verbinal/exec", "PUT .verbinal/exec", "PUT .verbinal/exec/inbox"],
                       "the folder that is there is not made; below a new one nothing is asked")
    }
}
