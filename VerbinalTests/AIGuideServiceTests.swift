// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Unit coverage for ``AIGuideService``: description overrides, custom guide
/// tools, validation, and the `Sendable` snapshot the MCP bridge consumes. All
/// on an in-memory DB — no disk, no network.
@MainActor
final class AIGuideServiceTests: XCTestCase {

    private func makeService() throws -> AIGuideService {
        AIGuideService(database: try .makeInMemory())
    }

    // MARK: - Overrides

    func testSetOverrideThenEffectiveDescription() throws {
        let svc = try makeService()
        XCTAssertEqual(svc.effectiveDescription(toolName: "find_observations", default: "Built-in"), "Built-in")

        try svc.setOverride(toolName: "find_observations", description: "Prefer CFHT MegaCam fields.")
        XCTAssertTrue(svc.isOverridden("find_observations"))
        XCTAssertEqual(svc.effectiveDescription(toolName: "find_observations", default: "Built-in"),
                       "Prefer CFHT MegaCam fields.")
    }

    func testOverridePersistsAcrossReload() throws {
        let db = try AppDatabase.makeInMemory()
        let svc = AIGuideService(database: db)
        try svc.setOverride(toolName: "get_preview_image", description: "Use band G when unsure.")

        // A second service over the same DB sees the persisted row.
        let svc2 = AIGuideService(database: db)
        XCTAssertEqual(svc2.overrides["get_preview_image"], "Use band G when unsure.")
    }

    func testClearOverrideRestoresDefault() throws {
        let svc = try makeService()
        try svc.setOverride(toolName: "tool_a", description: "Custom.")
        svc.clearOverride(toolName: "tool_a")
        XCTAssertFalse(svc.isOverridden("tool_a"))
        XCTAssertEqual(svc.effectiveDescription(toolName: "tool_a", default: "Default."), "Default.")
    }

    func testEmptyOverrideClears() throws {
        let svc = try makeService()
        try svc.setOverride(toolName: "tool_a", description: "Custom.")
        try svc.setOverride(toolName: "tool_a", description: "   ")
        XCTAssertFalse(svc.isOverridden("tool_a"))
    }

    func testOverrideTooLongThrows() throws {
        let svc = try makeService()
        let huge = String(repeating: "x", count: AIGuideService.maxDescriptionChars + 1)
        XCTAssertThrowsError(try svc.setOverride(toolName: "tool_a", description: huge)) { error in
            XCTAssertEqual(error as? AIGuideError, .tooLong(field: "Description", limit: AIGuideService.maxDescriptionChars))
        }
    }

    // MARK: - Guide tools

    func testAddGuideCreatesSluggedTool() throws {
        let svc = try makeService()
        let entry = try svc.addGuide(name: "Batch Download Strategy", description: "How I like bulk downloads.", body: "Step 1...")
        XCTAssertEqual(entry.name, "batch_download_strategy")
        XCTAssertEqual(svc.guides.count, 1)
        XCTAssertEqual(svc.guides.first?.name, "batch_download_strategy")
    }

    func testGuideSnapshotBodyAndDescriptionFallback() throws {
        let svc = try makeService()
        try svc.addGuide(name: "With Body", description: "desc", body: "the body")
        try svc.addGuide(name: "No Body", description: "just the description", body: nil)
        let snap = svc.snapshot()
        XCTAssertEqual(snap.guideBody(forName: "with_body"), "the body")
        XCTAssertEqual(snap.guideBody(forName: "no_body"), "just the description")
        XCTAssertNil(snap.guideBody(forName: "does_not_exist"))
    }

    func testGuideNameEmptyThrows() throws {
        let svc = try makeService()
        XCTAssertThrowsError(try svc.addGuide(name: "   ", description: "d", body: nil)) { error in
            XCTAssertEqual(error as? AIGuideError, .nameEmpty)
        }
        // A name that sanitizes to nothing (only punctuation) is also empty.
        XCTAssertThrowsError(try svc.addGuide(name: "!!!", description: "d", body: nil)) { error in
            XCTAssertEqual(error as? AIGuideError, .nameEmpty)
        }
    }

    func testGuideNameCollidesWithBuiltInTool() throws {
        let svc = try makeService()
        svc.knownToolNames = ["find_observations"]
        XCTAssertThrowsError(try svc.addGuide(name: "Find Observations", description: "d", body: nil)) { error in
            XCTAssertEqual(error as? AIGuideError, .nameCollidesWithTool)
        }
    }

    func testGuideNameDuplicateThrows() throws {
        let svc = try makeService()
        try svc.addGuide(name: "My Guide", description: "d", body: nil)
        XCTAssertThrowsError(try svc.addGuide(name: "my guide", description: "d2", body: nil)) { error in
            XCTAssertEqual(error as? AIGuideError, .nameTaken)
        }
    }

    func testUpdateGuideKeepsItsOwnNameValid() throws {
        let svc = try makeService()
        let entry = try svc.addGuide(name: "Editable", description: "old", body: nil)
        // Updating with the same (slugged) name must NOT trip the duplicate check.
        try svc.updateGuide(id: entry.id, name: "Editable", description: "new", body: "added body")
        XCTAssertEqual(svc.guides.first?.description, "new")
        XCTAssertEqual(svc.guides.first?.body, "added body")
    }

    func testDeleteGuideRemovesItAndFreesTheName() throws {
        let svc = try makeService()
        let entry = try svc.addGuide(name: "Temp Guide", description: "d", body: nil)
        svc.deleteGuide(id: entry.id)
        XCTAssertTrue(svc.guides.isEmpty)
        // The freed name can be reused (uniqueness is enforced over LIVE rows).
        XCTAssertNoThrow(try svc.addGuide(name: "Temp Guide", description: "d2", body: nil))
        XCTAssertEqual(svc.guides.count, 1)
    }

    func testGuidesPersistAndOrderAcrossReload() throws {
        let db = try AppDatabase.makeInMemory()
        let svc = AIGuideService(database: db)
        try svc.addGuide(name: "First", description: "1", body: nil)
        try svc.addGuide(name: "Second", description: "2", body: nil)

        let svc2 = AIGuideService(database: db)
        XCTAssertEqual(svc2.guides.map(\.name), ["first", "second"])
    }

    func testGuideBodyTooLongThrows() throws {
        let svc = try makeService()
        let huge = String(repeating: "y", count: AIGuideService.maxBodyChars + 1)
        XCTAssertThrowsError(try svc.addGuide(name: "Big", description: "d", body: huge)) { error in
            XCTAssertEqual(error as? AIGuideError, .tooLong(field: "Instructions", limit: AIGuideService.maxBodyChars))
        }
    }

    // MARK: - Slug

    func testSlugSanitization() {
        XCTAssertEqual(AIGuideService.slug("Batch Download Strategy"), "batch_download_strategy")
        XCTAssertEqual(AIGuideService.slug("  Trim  Me  "), "trim_me")
        XCTAssertEqual(AIGuideService.slug("weird---chars...here"), "weird_chars_here")
        XCTAssertEqual(AIGuideService.slug("Café Notes"), "caf_notes")  // non-ASCII dropped
        XCTAssertEqual(AIGuideService.slug("!!!"), "")
        XCTAssertEqual(AIGuideService.slug("already_ok"), "already_ok")
    }

    // MARK: - rows(forTools:) merge

    func testRowsMergeOverrides() throws {
        let svc = try makeService()
        try svc.setOverride(toolName: "b", description: "override b")
        let rows = svc.rows(forTools: [
            .init(name: "a", defaultDescription: "default a", category: "Cat"),
            .init(name: "b", defaultDescription: "default b", category: "Cat"),
        ])
        XCTAssertEqual(rows[0].effectiveDescription, "default a")
        XCTAssertFalse(rows[0].isOverridden)
        XCTAssertEqual(rows[1].effectiveDescription, "override b")
        XCTAssertTrue(rows[1].isOverridden)
    }
}
