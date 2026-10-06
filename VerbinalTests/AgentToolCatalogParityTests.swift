// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import Foundation
import VerbinalKit
@testable import Verbinal

/// Parity guardrails: the live tool registry and the AI Guide catalog
/// must agree in BOTH directions. A tool without a category silently
/// lands in "Other" on the AI Guide screen; a catalog entry without a
/// tool is dead weight that misleads the screen and this repo's parity
/// matrix (docs/agent-ui-parity.md).
final class AgentToolCatalogParityTests: XCTestCase {

    @MainActor
    func testEveryRegisteredToolHasACatalogCategoryAndUniqueName() {
        let tools = AppState().makeAgentTools()
        XCTAssertGreaterThan(tools.count, 100, "registry unexpectedly small — wiring broken?")

        var seen = Set<String>()
        var duplicates: [String] = []
        var uncategorized: [String] = []
        for tool in tools {
            if !seen.insert(tool.name).inserted { duplicates.append(tool.name) }
            if AIGuideCatalog.categoryID(forTool: tool.name) == AIGuideCatalog.guides.id {
                uncategorized.append(tool.name)
            }
        }
        XCTAssertTrue(duplicates.isEmpty, "duplicate tool names registered: \(duplicates)")
        XCTAssertTrue(uncategorized.isEmpty,
                      "tools missing an AIGuideCatalog category (add them): \(uncategorized)")
    }

    @MainActor
    func testEveryCatalogEntryMapsToARegisteredTool() {
        let registered = Set(AppState().makeAgentTools().map(\.name))
        let stale = AIGuideCatalog.allMappedToolNames.filter { !registered.contains($0) }
        XCTAssertTrue(stale.isEmpty,
                      "catalog entries with no registered tool (remove or wire them): \(stale)")
    }

    /// The apply rule is appended from `AutoApplyPolicy` at tools/list; a
    /// tool that spells its own copy can contradict it (several said a
    /// deletion "runs immediately when auto-apply is on").
    @MainActor
    func testNoToolSpellsItsOwnAutoApplyRule() {
        let handWritten = ["when auto-apply is on", "under auto-apply", "queues to the proposal strip",
                           "queues for confirmation", "queues for explicit confirmation"]
        let offenders = AppState().makeAgentTools().filter { tool in
            let text = tool.definition.description.lowercased()
            return handWritten.contains { text.contains($0) }
        }.map(\.name)
        XCTAssertTrue(offenders.isEmpty, "state the rule through AutoApplyPolicy, not by hand: \(offenders)")
    }

    func testCatalogCategoriesAreWellFormed() {
        let ids = AIGuideCatalog.categories.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate category ids")
        // Every mapped tool must point at a declared category.
        let known = Set(ids)
        let dangling = AIGuideCatalog.allMappedToolNames.filter {
            !known.contains(AIGuideCatalog.categoryID(forTool: $0))
        }
        XCTAssertTrue(dangling.isEmpty, "tools mapped to unknown category ids: \(dangling)")
    }

    @MainActor
    func testEveryAdvertisedInputSchemaIsAnObject() {
        let tools = AppState().makeAgentTools()
        var broken: [String] = []
        for tool in tools {
            let problems = ToolInputSchema.problems(in: tool.definition.inputSchema)
            if !problems.isEmpty {
                broken.append("\(tool.name): \(problems.joined(separator: "; "))")
            }
        }
        XCTAssertTrue(broken.isEmpty, "malformed inputSchema:\n\(broken.joined(separator: "\n"))")
    }

    @MainActor
    func testDescribeAppBacktickToolNamesAreRegistered() {
        let registered = Set(AppState().makeAgentTools().map(\.name))
        XCTAssertTrue(registered.contains("delete_saved_query"),
                      "delete_saved_query must stay on the live surface (describe_app advertises it)")
        let documented = Self.snakeCaseBacktickNames(in: DescribeAppTool.brief)
        XCTAssertTrue(documented.contains("delete_saved_query"))
        let unknown = documented.subtracting(registered)
        XCTAssertTrue(
            unknown.isEmpty,
            "describe_app names tools that are not registered: \(unknown.sorted())")
    }

    /// A tool's description that names another tool names one that exists:
    /// QA found `set_search_tab` in three descriptions, for `select_search_tab`.
    @MainActor
    func testEveryToolADescriptionNamesIsRegistered() {
        let tools = AppState().makeAgentTools()
        let registered = Set(tools.map(\.name))
        let verbs = ["get", "set", "list", "show", "open", "close", "select", "clear", "point", "run", "start",
                     "delete", "navigate", "annotate", "export", "load", "save", "remove", "add", "use", "launch"]
        let pattern = "\\b(" + verbs.joined(separator: "|") + ")_[a-z]+(?:_[a-z]+)*\\b"
        let regex = try! NSRegularExpression(pattern: pattern)
        var unknown: [String] = []
        for tool in tools {
            let text = tool.definition.description
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range)
                if !registered.contains(name) { unknown.append("\(tool.name) names \(name)") }
            }
        }
        XCTAssertTrue(unknown.isEmpty, "tool descriptions name tools that are not registered:\n" + unknown.joined(separator: "\n"))
    }

    /// Snake_case identifiers that appear inside backticks in the brief.
    /// Stops at the first non-name character so `get_proposal_state(id)`
    /// and `get_current_view.mode` still yield the tool name.
    private static func snakeCaseBacktickNames(in text: String) -> Set<String> {
        let pattern = "`([a-z][a-z0-9]*(?:_[a-z0-9]+)+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return Set(matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1))
        })
    }
}

/// start_background_apply may start only what the person allows without
/// asking (Windows 1.4.1 fixed an approval bypass here; plan 30 A).
final class BackgroundApplyPolicyTests: XCTestCase {
    private func proposal(_ tool: String) -> PendingProposal {
        PendingProposal(toolName: tool, kind: tool, summary: tool, payload: Data(), origin: .external(clientID: "test"))
    }

    func testOnlyWhatThePersonAllowsMayStart() {
        XCTAssertNil(AgentsService.backgroundRefusal(proposal("download_observation"), permissions: .defaults))
        XCTAssertNotNil(AgentsService.backgroundRefusal(proposal("download_observation"), permissions: .askForEverything))
        let destructive = AgentsService.backgroundRefusal(proposal("delete_vospace_node"), permissions: .defaults)
        XCTAssertTrue(destructive?.contains("Remove or replace in your CANFAR storage") ?? false)
        let standing = AgentsService.backgroundRefusal(proposal("add_guide_tool"), permissions: .defaults)
        XCTAssertTrue(standing?.contains("always waits") ?? false)
        var allowing = ChangePermissions.defaults
        allowing.set(.removeFromStorage, allowed: true)
        XCTAssertNil(AgentsService.backgroundRefusal(proposal("delete_vospace_node"), permissions: allowing),
                     "a destructive kind the person allows may start")
    }

    /// Plan 30 A: every tool that changes something has a kind; a destructive
    /// tool is in a destructive kind — but removing a guide tool, which
    /// changes what every assistant is told, always waits as one.
    @MainActor
    func testEveryChangingToolHasAKind() {
        let changing = AppState().makeAgentTools().filter {
            [.semanticWrite, .destructive, .standingInstruction].contains(type(of: $0).verbClass)
        }
        XCTAssertFalse(changing.isEmpty)
        for tool in changing {
            let name = tool.definition.name
            guard let kind = ChangeCatalog.kind(ofTool: name) else { XCTFail("\(name) has no kind"); continue }
            switch type(of: tool).verbClass {
            case .destructive where kind != .standingInstruction:
                XCTAssertTrue(kind.isDestructive, "\(name) is destructive, \(kind) is not")
            case .standingInstruction:
                XCTAssertEqual(kind, .standingInstruction, name)
            case .semanticWrite:
                XCTAssertFalse(kind.isDestructive, "\(name) adds or changes, \(kind) removes")
            default:
                break
            }
        }
        XCTAssertEqual(ChangeCatalog.kind(ofTool: "delete_guide_tool"), .standingInstruction)
        XCTAssertNil(ChangeCatalog.kind(ofTool: "navigate_to"), "a view change is no kind of change")
    }

    /// What waits says why, by the person's setting — not "auto-apply is off".
    func testWhatWaitsSaysWhy() {
        XCTAssertEqual(AgentsService.waitingRule(proposal("delete_session"), permissions: .defaults),
                       "waits in Pending: the person asks to approve \"Stop running work on CANFAR\"")
        XCTAssertTrue(AgentsService.waitingRule(proposal("launch_session"), permissions: .defaults)
            .contains("proposed before the person allowed"))
        let decision = ChangeCatalog.decision(for: proposal("launch_headless_job"), permissions: .defaults)
        XCTAssertTrue(decision.appliesAtOnce, "batch jobs allowed by default (decision 6)")
        XCTAssertEqual(decision.rule, "applied at once: the person allows \"Use your CANFAR allocation: batch jobs and image probes\"")
    }

    /// Plan 15 S1 (QA H6): the tools that write what every later agent is
    /// told — guide tools, tool descriptions — wait for the person.
    func testStandingInstructionsWaitForThePerson() {
        let classes = [SetToolDescriptionTool.verbClass, ClearToolDescriptionTool.verbClass,
                       AddGuideToolTool.verbClass, UpdateGuideToolTool.verbClass]
        XCTAssertEqual(classes, Array(repeating: .standingInstruction, count: 4))
        XCTAssertEqual(DeleteGuideToolTool.verbClass, .destructive)
    }
}
