// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Public files that usually hold secrets are said to be so (plan 15 S5,
/// QA M14: `.token`, `.config`, `.globus-init.sh`, `.bashrc` were public).
@MainActor
final class VOSpaceSensitivityTests: XCTestCase {

    func testTheNamesThatUsuallyHoldSecrets() {
        for path in [".token", ".config", ".globus-init.sh", ".bashrc", ".ssh/id_rsa", ".config/gh/hosts.yml",
                     ".netrc", "certs/cadcproxy.pem", "keys/deploy.KEY", "/home/u/.aws/credentials",
                     ".vnc/passwd", "home/u/.Xauthority"] {
            XCTAssertTrue(VOSpaceSensitivity.isLikelySecret(path), path)
        }
        for path in ["results/stack.fits", "notes.md", "tokens.txt", "config.yaml", "analysis/profile.py"] {
            XCTAssertFalse(VOSpaceSensitivity.isLikelySecret(path), path)
        }
    }

    func testOnlyAPublicOneIsExposed() {
        var token = VOSpaceNode(name: ".token", path: ".token", type: .dataNode)
        XCTAssertFalse(token.isExposedSecret)
        token.isPublic = true
        XCTAssertTrue(token.isExposedSecret)
        var stack = VOSpaceNode(name: "stack.fits", path: "results/stack.fits", type: .dataNode)
        stack.isPublic = true
        XCTAssertFalse(stack.isExposedSecret)
    }

    func testTheListingFlagsThemAndSaysWhatToDo() async throws {
        let nodes = [
            VOSpaceNodeOut(name: ".token", path: ".token", type: "dataNode", sizeBytes: 40, contentType: nil,
                           lastModified: nil, isPublic: true, exposedSecret: true),
            VOSpaceNodeOut(name: "stack.fits", path: "stack.fits", type: "dataNode", sizeBytes: 9, contentType: nil,
                           lastModified: nil, isPublic: true),
        ]
        let tool = ListVOSpacePathTool(listNodes: { _, _ in nodes })
        let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                budget: ProposalBudget(limit: 9))
        let out = try await tool.handle(.init(path: "", limit: 10), context: ctx)
        XCTAssertEqual(out.nodes.map(\.exposedSecret), [true, nil])
        let warning = try XCTUnwrap(out.warning)
        XCTAssertTrue(warning.contains(".token") && warning.contains("set_vospace_acl"), warning)
        XCTAssertFalse(warning.contains("stack.fits"))
    }

    /// Make Private sends the ACL change with only public access taken away.
    func testMakePrivateTakesAwayPublicAccessOnly() async throws {
        final class Sent: @unchecked Sendable { var posts: [String] = [] }
        let sent = Sent()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if request.httpMethod == "POST" {
                sent.posts.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            let xml = url.query?.contains("detail=min") == true
                ? #"<vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" uri="vos://cadc.nrc.ca~arc/home/u/.token" xsi:type="vos:DataNode"/>"#
                : #"<vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0" uri="vos://cadc.nrc.ca~arc/home/u"><vos:nodes/></vos:node>"#
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(xml.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let service = VOSpaceBrowserService(network: NetworkClient(session: MockURLProtocol.mockSession()))
        let model = StorageBrowserModel(service: service, username: "u", tasks: TaskRegistry())
        var token = VOSpaceNode(name: ".token", path: ".token", type: .dataNode)
        token.isPublic = true
        model.nodes = [token]
        XCTAssertEqual(model.exposedSecrets.map(\.name), [".token"])

        await model.makePrivate(model.exposedSecrets)

        let body = try XCTUnwrap(sent.posts.first)
        XCTAssertTrue(body.contains("#ispublic\">false<"), body)
        XCTAssertFalse(body.contains("#groupread"), "groups are left as they are")
        XCTAssertFalse(model.hasError, model.errorMessage)
    }
}
