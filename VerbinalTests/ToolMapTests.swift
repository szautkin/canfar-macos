// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import MCPCore
import VerbinalKit
@testable import Verbinal

/// list_apps / search_tools / man / describe_app(app:) — the map of the
/// tool surface, read from the tool list exactly as agents get it.
final class ToolMapTests: XCTestCase {

    private func tool(_ name: String, _ description: String) -> ToolDefinitionWire {
        ToolDefinitionWire(name: name, description: description,
                           inputSchema: .object(["type": .string("object")]))
    }

    private lazy var tools: [ToolDefinitionWire] = [
        tool("probe_cube_spectrum", "Read the spectrum under one spaxel of the open cube. More text."),
        tool("get_cube_view", "Read the Cube Viewer's state."),
        tool("fits_goto_coordinate", "Center the FITS view on a sky position."),
        tool("run_search", "Press the Search button."),
    ]

    private func ctx() -> AIToolContext {
        AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(),
                      budget: ProposalBudget(limit: 9))
    }

    func testAreasCountTheirToolsInCatalogOrder() {
        let areas = ToolMap.areas(tools)
        XCTAssertEqual(areas.map(\.id), ["search", "fits", "cube"])
        XCTAssertEqual(areas.first { $0.id == "cube" }?.toolCount, 2)
    }

    /// "cube spectrum" matched as one phrase found nothing (Windows 1.4.1).
    func testSearchMatchesWordsNotThePhrase() {
        let hits = ToolMap.search("cube spectrum", area: nil, in: tools)
        XCTAssertEqual(hits.first?.name, "probe_cube_spectrum")
        XCTAssertEqual(hits.first?.appID, "cube")
    }

    func testSearchNeedsMostWordsAndRanksNameHitsFirst() {
        XCTAssertTrue(ToolMap.search("cube banana", area: nil, in: tools).isEmpty, "both of two words must appear")
        let cube = ToolMap.search("cube", area: nil, in: tools).map(\.name)
        XCTAssertEqual(Set(cube), ["probe_cube_spectrum", "get_cube_view"])
        XCTAssertEqual(ToolMap.search("cube", area: "fits", in: tools), [])
    }

    func testSummaryIsTheFirstSentence() {
        XCTAssertEqual(ToolMap.summary(of: "Read the spectrum. More text."), "Read the spectrum.")
    }

    func testManGivesTheSchemaOrTheNearestNames() async throws {
        let list = tools
        let man = ManTool(published: { list })
        let hit = try await man.handle(.init(tool: "PROBE_CUBE_SPECTRUM"), context: ctx())
        XCTAssertTrue(hit.found)
        XCTAssertEqual(hit.tool, "probe_cube_spectrum")
        XCTAssertNotNil(hit.inputSchema)

        let miss = try await man.handle(.init(tool: "cube_spectrum"), context: ctx())
        XCTAssertFalse(miss.found)
        XCTAssertEqual(miss.didYouMean, ["probe_cube_spectrum", "get_cube_view"],
                       "a name holding the whole guess first, then one sharing a word")
    }

    func testDescribeAppGivesOneAreasTools() async throws {
        let list = tools
        var describe = DescribeAppTool()
        describe.published = { list }
        let whole = try await describe.handle(.init(app: nil), context: ctx())
        XCTAssertNotNil(whole.brief)
        // Plan 21 V: which build answers — its version and the commit it was built from.
        XCTAssertEqual(whole.serverVersion, "1.4.0")
        XCTAssertNotNil(whole.buildCommit?.range(of: #"^[0-9a-f]{7,}\+?$"#, options: .regularExpression), whole.buildCommit ?? "nil")
        let cube = try await describe.handle(.init(app: "cube"), context: ctx())
        XCTAssertNil(cube.brief)
        XCTAssertEqual(cube.tools?.map(\.name), ["get_cube_view", "probe_cube_spectrum"])
        do {
            _ = try await describe.handle(.init(app: "nowhere"), context: ctx())
            XCTFail("an unknown area must be refused")
        } catch let failure as ToolFailureReason {
            guard case .invalidArgument(let why) = failure else { return XCTFail("\(failure)") }
            XCTAssertTrue(why.contains("cube"), why)
        }
    }

    // MARK: - The person's standing rules (plan 15 S3, QA M10)

    private let guides = AIGuideSnapshot(overrides: [:], guides: [
        AIGuideToolEntry(id: UUID(), name: "storage_rules", description: "Where results go in my VOSpace home", body: "Write to /results only."),
        AIGuideToolEntry(id: UUID(), name: "headless_jobs_rules", description: "How to launch batch jobs", body: nil),
    ])

    func testDescribeAppOpensWithThePersonsRules() async throws {
        var describe = DescribeAppTool()
        let rules = guides.standingRules
        describe.standingRules = { rules }
        let whole = try await describe.handle(.init(app: nil), context: ctx())
        XCTAssertEqual(whole.standingRules?.map(\.tool), ["storage_rules", "headless_jobs_rules"])
        let brief = try XCTUnwrap(whole.brief)
        XCTAssertTrue(brief.hasPrefix("## The person's standing rules"), String(brief.prefix(80)))
        XCTAssertTrue(brief.contains("- `storage_rules` — Where results go in my VOSpace home"))

        var none = DescribeAppTool()
        none.standingRules = { [] }
        let plain = try await none.handle(.init(app: nil), context: ctx())
        XCTAssertEqual(plain.brief, DescribeAppTool.brief, "no rules, no section")
    }

    func testTheCurrentViewNamesTheRules() throws {
        var view = GetCurrentViewTool.Output(
            mode: "landing", modeTitle: "Landing", isAuthenticated: false, username: "",
            searchFocusRA: nil, searchFocusDec: nil, searchTab: nil, searchResultsTotal: nil, searchResultsFiltered: nil,
            openFITSPaths: [], pendingViewerChoice: nil, pendingProposalsCount: 0,
            agentsEnabled: true, autoApplyEnabled: true, followAgentActivityEnabled: true)
        view.standingRules = guides.standingRules
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as? [String: Any])
        let rules = try XCTUnwrap(json["standingRules"] as? [[String: String]])
        XCTAssertEqual(rules.first, ["tool": "storage_rules", "says": "Where results go in my VOSpace home"])
        let shown = view
        XCTAssertTrue(GetCurrentViewTool(snapshot: { shown }).definition.description.hasPrefix("Return the person's standing rules"),
                      "JSON keys have no order; the description is where they come first")
    }
}
