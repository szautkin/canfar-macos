// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Network-level coverage for recursive VOSpace delete (UI + MCP share
/// `VOSpaceBrowserService.deleteNode(recursive:)`).
final class VOSpaceRecursiveDeleteTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeService(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> VOSpaceBrowserService {
        MockURLProtocol.requestHandler = { req in try handler(req) }
        return VOSpaceBrowserService(network: NetworkClient(session: MockURLProtocol.mockSession()))
    }

    private func ok(_ url: URL, body: Data = Data()) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }

    private func listingXML(parentURI: String, children: [(uri: String, container: Bool)]) -> Data {
        let kids = children.map { child in
            let type = child.container ? "vos:ContainerNode" : "vos:DataNode"
            return """
            <vos:node uri="\(child.uri)" xsi:type="\(type)">
              <vos:properties/>
            </vos:node>
            """
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                  uri="\(parentURI)"
                  xsi:type="vos:ContainerNode">
          <vos:nodes>\(kids)</vos:nodes>
        </vos:node>
        """.utf8)
    }

    /// Post-order: child file DELETE before parent folder DELETE.
    func testRecursiveDeleteRemovesChildrenThenParent() async throws {
        var deletes: [String] = []
        var gets: [String] = []
        let service = makeService { request in
            let url = request.url!
            let absolute = url.absoluteString
            if request.httpMethod == "DELETE" {
                deletes.append(absolute)
                return self.ok(url)
            }
            gets.append(absolute)
            // Same listing shape as the model test that already passes.
            if absolute.contains("/testuser/trash") && !absolute.contains("/trash/") {
                let body = Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                          uri="vos://cadc.nrc.ca~arc/home/testuser/trash"
                          xsi:type="vos:ContainerNode">
                  <vos:nodes>
                    <vos:node uri="vos://cadc.nrc.ca~arc/home/testuser/trash/a.txt"
                              xsi:type="vos:DataNode"><vos:properties/></vos:node>
                    <vos:node uri="vos://cadc.nrc.ca~arc/home/testuser/trash/b.txt"
                              xsi:type="vos:DataNode"><vos:properties/></vos:node>
                  </vos:nodes>
                </vos:node>
                """.utf8)
                return self.ok(url, body: body)
            }
            let empty = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                      uri="vos://cadc.nrc.ca~arc/home/testuser/trash/leaf"
                      xsi:type="vos:ContainerNode">
              <vos:nodes/>
            </vos:node>
            """.utf8)
            return self.ok(url, body: empty)
        }

        // Prove the listing path parses two children before deleting.
        let listed = try await service.listNodes(username: "testuser", path: "trash")
        XCTAssertEqual(listed.map(\.name).sorted(), ["a.txt", "b.txt"], "gets=\(gets)")

        let count = try await service.deleteNode(
            username: "testuser",
            path: "trash",
            recursive: true
        )
        XCTAssertEqual(count, 3, "expected 2 files + folder; deletes=\(deletes) gets=\(gets)")
        XCTAssertEqual(deletes.count, 3, "deletes=\(deletes)")
        guard deletes.count == 3 else { return }
        XCTAssertTrue(
            deletes[0].contains("/trash/a.txt") || deletes[0].contains("/trash/b.txt"),
            deletes[0]
        )
        XCTAssertTrue(
            deletes[1].contains("/trash/a.txt") || deletes[1].contains("/trash/b.txt"),
            deletes[1]
        )
        XCTAssertTrue(deletes[2].contains("/trash"), deletes[2])
        XCTAssertFalse(deletes[2].contains(".txt"), "parent should be last: \(deletes[2])")
        XCTAssertNotEqual(deletes[0], deletes[1])
    }

    func testNonRecursiveSingleDelete() async throws {
        var deletes = 0
        let service = makeService { request in
            let url = request.url!
            XCTAssertEqual(request.httpMethod, "DELETE")
            deletes += 1
            return self.ok(url)
        }
        let count = try await service.deleteNode(
            username: "testuser",
            path: "solo.fits",
            recursive: false
        )
        XCTAssertEqual(count, 1)
        XCTAssertEqual(deletes, 1)
    }

    func testNonRecursiveConflictMapsToNotEmptyError() async {
        let service = makeService { request in
            let url = request.url!
            // NetworkClient.execute throws on ≥400 — return 409 body.
            return (
                HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!,
                Data("conflict".utf8)
            )
        }
        do {
            _ = try await service.deleteNode(
                username: "testuser",
                path: "full_folder",
                recursive: false
            )
            XCTFail("expected not-empty error")
        } catch let error as VOSpaceError {
            let msg = error.localizedDescription ?? ""
            XCTAssertTrue(
                msg.localizedCaseInsensitiveContains("not empty")
                    || msg.localizedCaseInsensitiveContains("pas vide"),
                "got: \(msg)"
            )
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    @MainActor
    func testModelDeletesFolderRecursively() async throws {
        var deletes: [String] = []
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let absolute = url.absoluteString
            if request.httpMethod == "DELETE" {
                deletes.append(absolute)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            if absolute.contains("/home/testuser/nest?") || absolute.hasSuffix("/home/testuser/nest") {
                let body = Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                          uri="vos://cadc.nrc.ca~arc/home/testuser/nest"
                          xsi:type="vos:ContainerNode">
                  <vos:nodes>
                    <vos:node uri="vos://cadc.nrc.ca~arc/home/testuser/nest/x.txt"
                              xsi:type="vos:DataNode"><vos:properties/></vos:node>
                  </vos:nodes>
                </vos:node>
                """.utf8)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body
                )
            }
            let empty = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <vos:node xmlns:vos="http://www.ivoa.net/xml/VOSpace/v2.0"
                      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                      uri="vos://cadc.nrc.ca~arc/home/testuser"
                      xsi:type="vos:ContainerNode">
              <vos:nodes/>
            </vos:node>
            """.utf8)
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                empty
            )
        }
        let network = NetworkClient(session: MockURLProtocol.mockSession())
        let service = VOSpaceBrowserService(network: network)
        let model = StorageBrowserModel(service: service, username: "testuser")
        model.selectedNode = VOSpaceNode(
            name: "nest",
            path: "nest",
            type: .container
        )
        await model.deleteSelected()
        XCTAssertFalse(model.isDeleting)
        XCTAssertNil(model.selectedNode)
        XCTAssertEqual(deletes.count, 2, "deletes=\(deletes)")
        if deletes.count == 2 {
            XCTAssertTrue(deletes[0].contains("/nest/x.txt"), deletes[0])
            XCTAssertTrue(deletes[1].hasSuffix("/nest") || deletes[1].contains("/nest?"), deletes[1])
        }
        XCTAssertTrue(
            model.statusMessage.contains("2")
                || model.statusMessage.localizedCaseInsensitiveContains("Deleted")
                || model.statusMessage.localizedCaseInsensitiveContains("supprim"),
            "got \(model.statusMessage)"
        )
    }
}
