// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import MCPCore
import VerbinalKit
@testable import Verbinal

/// Plan 23 K across the app's own tools and tasks.
final class CauseWiringTests: XCTestCase {

    private func properties(_ schema: JSONValue) -> [String: JSONValue] {
        guard case .object(let root) = schema, case .object(let properties)? = root["properties"] else { return [:] }
        return properties
    }

    /// Every change the app offers an assistant takes `why`; no read does;
    /// and no tool declares `why` itself, which the router would take off.
    @MainActor
    func testEveryChangeToolTakesWhyAndNoneDeclaresItsOwn() async throws {
        let tools = AppState().makeAgentTools()
        let router = AIToolRouter(tools: tools, auditSink: CapturingAuditSink())
        let published = await PublishedManifest.tools(router: router, aiGuide: nil)
        var changes = 0
        for tool in tools {
            XCTAssertNil(properties(tool.definition.inputSchema)["why"], "\(tool.name) declares its own why")
            guard let wire = published.first(where: { $0.name == tool.name }),
                  let verbClass = await router.verbClass(of: tool.name) else { continue }
            if verbClass.proposesChange { changes += 1 }
            XCTAssertEqual(properties(wire.inputSchema)["why"] != nil, verbClass.proposesChange, tool.name)
        }
        XCTAssertGreaterThan(changes, 40, "the write tools were not found")
    }

    @MainActor
    func testATrackedTaskKeepsItsWhyAndItsWorkRunsUnderIt() async {
        let registry = TaskRegistry()
        let seen = await registry.track(.research, "Check records", by: .app, why: "at sign-in, the rule") { _ in
            Cause.current.why
        }
        XCTAssertEqual(seen, "at sign-in, the rule")
        XCTAssertEqual(registry.tasks.first?.cause.why, "at sign-in, the rule")
    }

    @MainActor
    func testATaskBegunInACallKeepsTheCallAndSession() async {
        let registry = TaskRegistry()
        let cause = Cause(why: "throwaway", session: UUID(), call: UUID())
        let handle = Cause.$current.withValue(cause) { registry.begin(.session, "Delete session x") }
        handle.succeed()
        XCTAssertEqual(registry.tasks.first?.cause, cause)
    }
}
