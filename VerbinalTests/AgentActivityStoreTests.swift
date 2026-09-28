// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

@MainActor
final class AgentActivityStoreTests: XCTestCase {

    private func makeStore(fileName: String? = nil) -> AgentActivityStore {
        AgentActivityStore(fileName: fileName ?? "test_agent_activity_\(UUID().uuidString).json")
    }

    private func makeEntry(
        proposalID: UUID? = nil,
        outcome: AgentActivityEntry.Outcome = .applied,
        autoApplied: Bool = false,
        summary: String = "Did a thing"
    ) -> AgentActivityEntry {
        AgentActivityEntry(
            kind: "test",
            summary: summary,
            originFingerprint: "fp",
            originLabel: "label",
            proposalID: proposalID,
            outcome: outcome,
            autoApplied: autoApplied
        )
    }

    override func tearDown() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal") {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("test_agent_activity_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        super.tearDown()
    }

    // MARK: - append()

    func testAppendInsertsAtFront() {
        let store = makeStore()
        let first = makeEntry(summary: "first")
        let second = makeEntry(summary: "second")

        store.append(first)
        store.append(second)

        XCTAssertEqual(store.entries.count, 2)
        // Reverse-chronological: most recently appended is at index 0.
        XCTAssertEqual(store.entries[0].id, second.id)
        XCTAssertEqual(store.entries[1].id, first.id)
    }

    func testAppendTrimsTailToCap() {
        let store = makeStore()
        let cap = store.cap

        // Append cap + 5 entries; track the most-recent one.
        var lastID: UUID?
        for i in 0..<(cap + 5) {
            let entry = makeEntry(summary: "entry \(i)")
            store.append(entry)
            lastID = entry.id
        }

        XCTAssertEqual(store.entries.count, cap, "count must not exceed the cap")
        // Front is the newest; the oldest entries fell off the tail.
        XCTAssertEqual(store.entries.first?.id, lastID)
    }

    func testAppendAtExactCapDoesNotTrim() {
        let store = makeStore()
        let cap = store.cap

        for i in 0..<cap {
            store.append(makeEntry(summary: "entry \(i)"))
        }

        XCTAssertEqual(store.entries.count, cap)
    }

    // MARK: - entry(forProposal:)

    func testEntryForProposalReturnsMatch() {
        let store = makeStore()
        let pid = UUID()
        store.append(makeEntry(proposalID: UUID(), summary: "other"))
        let target = makeEntry(proposalID: pid, summary: "target")
        store.append(target)

        let found = store.entry(forProposal: pid)
        XCTAssertEqual(found?.id, target.id)
        XCTAssertEqual(found?.proposalID, pid)
    }

    func testEntryForProposalReturnsNilForUnknownID() {
        let store = makeStore()
        store.append(makeEntry(proposalID: UUID()))

        XCTAssertNil(store.entry(forProposal: UUID()))
    }

    // MARK: - markApplied(forProposal:by:) — plan 15 S2

    func testMarkAppliedSaysWhoAppliedIt() {
        let store = makeStore()
        let byAuto = UUID(), byPerson = UUID()
        store.append(makeEntry(proposalID: byAuto, outcome: .applied, autoApplied: false))
        store.append(makeEntry(proposalID: byPerson, outcome: .applied, autoApplied: false))

        store.markApplied(forProposal: byAuto, by: .autoApply)
        store.markApplied(forProposal: byPerson, by: .person)

        XCTAssertEqual(store.entry(forProposal: byAuto)?.appliedBy, .autoApply)
        XCTAssertEqual(store.entry(forProposal: byAuto)?.autoApplied, true)
        XCTAssertEqual(store.entry(forProposal: byPerson)?.appliedBy, .person)
        XCTAssertEqual(store.entry(forProposal: byPerson)?.autoApplied, false)
    }

    func testMarkAppliedPreservesOtherFields() {
        let store = makeStore()
        let pid = UUID()
        let original = makeEntry(proposalID: pid, outcome: .applied, autoApplied: false, summary: "keep me")
        store.append(original)

        store.markApplied(forProposal: pid, by: .background)

        let updated = store.entry(forProposal: pid)
        XCTAssertEqual(updated?.id, original.id)
        XCTAssertEqual(updated?.timestamp, original.timestamp)
        XCTAssertEqual(updated?.summary, "keep me")
        XCTAssertEqual(updated?.outcome, .applied)
        XCTAssertEqual(updated?.appliedBy, .background)
    }

    func testMarkAppliedIsNoOpForRejectedAndWithdrawn() {
        let store = makeStore()
        let rejected = UUID(), withdrawn = UUID()
        store.append(makeEntry(proposalID: rejected, outcome: .rejected, autoApplied: false))
        store.append(makeEntry(proposalID: withdrawn, outcome: .withdrawn, autoApplied: false))

        store.markApplied(forProposal: rejected, by: .autoApply)
        store.markApplied(forProposal: withdrawn, by: .autoApply)

        XCTAssertNil(store.entry(forProposal: rejected)?.appliedBy)
        XCTAssertNil(store.entry(forProposal: withdrawn)?.appliedBy)
    }

    func testMarkAppliedKeepsTheFirstActor() {
        let store = makeStore()
        let pid = UUID()
        store.append(makeEntry(proposalID: pid, outcome: .applied, autoApplied: false))
        store.markApplied(forProposal: pid, by: .person)
        let stamped = store.entry(forProposal: pid)

        store.markApplied(forProposal: pid, by: .autoApply)

        XCTAssertEqual(store.entry(forProposal: pid), stamped)
    }

    func testMarkAppliedIsNoOpForUnknownProposal() {
        let store = makeStore()
        store.append(makeEntry(proposalID: UUID(), outcome: .applied, autoApplied: false))
        let before = store.entries

        store.markApplied(forProposal: UUID(), by: .person)

        XCTAssertEqual(store.entries, before)
    }

    // MARK: - clear()

    func testClearEmptiesEntries() {
        let store = makeStore()
        store.append(makeEntry())
        store.append(makeEntry())
        XCTAssertEqual(store.entries.count, 2)

        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testClearPersistsEmptyArray() {
        let fileName = "test_agent_activity_clear_\(UUID().uuidString).json"
        let store1 = makeStore(fileName: fileName)
        store1.append(makeEntry())
        store1.clear()

        // Re-init from the same file: the empty array must survive.
        let store2 = makeStore(fileName: fileName)
        XCTAssertTrue(store2.entries.isEmpty)
    }

    // MARK: - Disk round-trip

    func testEntriesReloadFromDiskOnReInit() {
        let fileName = "test_agent_activity_persist_\(UUID().uuidString).json"
        let pid = UUID()

        let store1 = makeStore(fileName: fileName)
        store1.append(makeEntry(summary: "older"))
        store1.append(makeEntry(proposalID: pid, summary: "newer"))
        XCTAssertEqual(store1.entries.count, 2)

        let store2 = makeStore(fileName: fileName)
        XCTAssertEqual(store2.entries.count, 2)
        // Order preserved across the round-trip (newest first).
        XCTAssertEqual(store2.entries[0].summary, "newer")
        XCTAssertEqual(store2.entries[1].summary, "older")
        XCTAssertEqual(store2.entry(forProposal: pid)?.summary, "newer")
    }
}
