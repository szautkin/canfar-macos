// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Wire-format coverage for `set_vospace_acl` — ports the Windows client's
/// regression tests (container child-element tail, DataNode short form,
/// three-valued dimension semantics) so both platforms pin the same
/// cavern-validator contract.
final class VOSpaceACLTests: XCTestCase {

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"),
                      proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 9))
    }

    // MARK: - XML builder

    /// Cavern 400s a ContainerNode setNode document without the
    /// accepts/provides/capabilities/nodes sequence — the tail must be there.
    func testContainerNodeIncludesChildElementSequence() {
        let xml = VOSpaceXMLParser.buildSetACLNodeXml(
            nodeURI: "vos://cadc.nrc.ca~arc/home/alice/results",
            nodeType: .container,
            groupRead: nil, groupWrite: nil, isPublic: true)
        XCTAssertTrue(xml.contains(#"xsi:type="vos:ContainerNode""#))
        for tag in ["<vos:accepts/>", "<vos:provides/>", "<vos:capabilities/>", "<vos:nodes/>"] {
            XCTAssertTrue(xml.contains(tag), "missing container tail element \(tag)")
        }
    }

    /// DataNode keeps the short form the validator tolerates.
    func testDataNodeOmitsContainerChildElements() {
        let xml = VOSpaceXMLParser.buildSetACLNodeXml(
            nodeURI: "vos://cadc.nrc.ca~arc/home/alice/stack.fits",
            nodeType: .dataNode,
            groupRead: ["ivo://cadc.nrc.ca/gms?TEAM"], groupWrite: nil, isPublic: nil)
        XCTAssertTrue(xml.contains(#"xsi:type="vos:DataNode""#))
        XCTAssertFalse(xml.contains("<vos:accepts/>"))
        XCTAssertFalse(xml.contains("<vos:nodes/>"))
    }

    /// nil = property omitted (unchanged); [] = empty property (revoke all);
    /// values = space-joined replacement list.
    func testThreeValuedDimensionSemantics() {
        let unchanged = VOSpaceXMLParser.buildSetACLNodeXml(
            nodeURI: "u", nodeType: .dataNode,
            groupRead: nil, groupWrite: nil, isPublic: true)
        XCTAssertFalse(unchanged.contains("#groupread"))
        XCTAssertFalse(unchanged.contains("#groupwrite"))
        XCTAssertTrue(unchanged.contains("#ispublic\">true<"))

        let revoked = VOSpaceXMLParser.buildSetACLNodeXml(
            nodeURI: "u", nodeType: .dataNode,
            groupRead: [], groupWrite: nil, isPublic: nil)
        XCTAssertTrue(revoked.contains(#"uri="ivo://ivoa.net/vospace/core#groupread"></vos:property>"#))

        let replaced = VOSpaceXMLParser.buildSetACLNodeXml(
            nodeURI: "u", nodeType: .dataNode,
            groupRead: nil,
            groupWrite: ["ivo://cadc.nrc.ca/gms?A", " ivo://cadc.nrc.ca/gms?B "],
            isPublic: nil)
        XCTAssertTrue(replaced.contains("ivo://cadc.nrc.ca/gms?A ivo://cadc.nrc.ca/gms?B"),
                      "groups must be trimmed and space-joined (the cavern delimiter)")
    }

    func testRootNodeTypeParsing() {
        XCTAssertEqual(VOSpaceXMLParser.parseRootNodeType(
            #"<vos:node xmlns:vos="x" uri="u" xsi:type="vos:ContainerNode"><vos:nodes/></vos:node>"#), .container)
        XCTAssertEqual(VOSpaceXMLParser.parseRootNodeType(
            #"<vos:node uri="u" xsi:type="vos:DataNode"/>"#), .dataNode)
        XCTAssertEqual(VOSpaceXMLParser.parseRootNodeType(
            #"<vos:node uri="u" xsi:type="vos:LinkNode"/>"#), .linkNode)
        // Parse failure defaults to container (the stricter document form).
        XCTAssertEqual(VOSpaceXMLParser.parseRootNodeType("garbage"), .container)
    }

    // MARK: - Tool plan validation

    func testPlanRequiresAtLeastOneDimension() async {
        do {
            _ = try await SetVOSpaceACLTool().plan(
                .init(path: "results", groupRead: nil, groupWrite: nil, isPublic: nil), context: ctx())
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        } catch { XCTFail("unexpected: \(error)") }
    }

    func testPlanRejectsTraversalAndSpellsOutACL() async throws {
        do {
            _ = try await SetVOSpaceACLTool().plan(
                .init(path: "a/../b", groupRead: nil, groupWrite: nil, isPublic: true), context: ctx())
            XCTFail("expected invalidArgument for traversal")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        } catch { XCTFail("unexpected: \(error)") }

        let plan = try await SetVOSpaceACLTool().plan(
            .init(path: "results", groupRead: [], groupWrite: nil, isPublic: true), context: ctx())
        XCTAssertEqual(plan.kind, "set_vospace_acl")
        XCTAssertTrue(plan.summary.contains("revoke all groups"))
        XCTAssertTrue(plan.summary.contains("world-readable"))
    }

    // MARK: - export_cube_figure plan

    func testExportCubeFigurePlanValidatesScale() async throws {
        do {
            _ = try await ExportCubeFigureTool().plan(.init(scale: 9), context: ctx())
            XCTFail("expected invalidArgument")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        } catch { XCTFail("unexpected: \(error)") }

        let plan = try await ExportCubeFigureTool().plan(.init(scale: nil), context: ctx())
        let payload = try JSONDecoder().decode(ExportCubeFigureTool.Payload.self, from: plan.payload)
        XCTAssertEqual(payload.scale, 2)
    }

    // MARK: - AI Guide tool plans

    func testGuideToolPlansValidate() async throws {
        do {
            _ = try await SetToolDescriptionTool().plan(
                .init(toolName: " ", description: "x"), context: ctx())
            XCTFail("expected invalidArgument for blank toolName")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        } catch { XCTFail("unexpected: \(error)") }

        let add = try await AddGuideToolTool().plan(
            .init(name: "team_conventions", description: "House rules", body: "Always…"), context: ctx())
        XCTAssertEqual(add.kind, "add_guide_tool")

        do {
            _ = try await DeleteGuideToolTool().plan(.init(id: "not-a-uuid"), context: ctx())
            XCTFail("expected invalidArgument for bad UUID")
        } catch let f as ToolFailureReason {
            guard case .invalidArgument = f else { return XCTFail("wrong case: \(f)") }
        } catch { XCTFail("unexpected: \(error)") }
    }
}
