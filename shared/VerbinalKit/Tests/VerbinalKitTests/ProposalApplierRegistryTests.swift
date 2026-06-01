// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VerbinalKit

// MARK: - Test doubles

/// Minimal applier that records whether `apply` ran. Identity is carried
/// by `id` so we can prove last-write-wins on duplicate-kind registration.
private struct MockApplier: ProposalApplier {
    let kind: String
    let id: Int

    func apply(_ proposal: PendingProposal) async throws {}
}

private func makeProposal(kind: String) -> PendingProposal {
    PendingProposal(
        toolName: kind,
        kind: kind,
        summary: "mock",
        payload: Data(),
        origin: .user
    )
}

final class ProposalApplierRegistryTests: XCTestCase {

    // register() then applier(for:) returns the registered applier;
    // unknown kind returns nil.
    func testRegisterThenLookupReturnsApplier() async {
        let registry = ProposalApplierRegistry()
        await registry.register(MockApplier(kind: "download", id: 1))

        let found = await registry.applier(for: "download")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.kind, "download")

        let missing = await registry.applier(for: "nope")
        XCTAssertNil(missing)
    }

    // Registering a second applier with the same kind overwrites the first
    // (last write wins).
    func testDuplicateKindOverwritesLastWriteWins() async {
        let registry = ProposalApplierRegistry()
        await registry.register(MockApplier(kind: "download", id: 1))
        await registry.register(MockApplier(kind: "download", id: 2))

        let found = await registry.applier(for: "download")
        let resolved = found as? MockApplier
        XCTAssertEqual(resolved?.id, 2)

        // Still exactly one entry for the kind.
        let kinds = await registry.registeredKinds()
        XCTAssertEqual(kinds, ["download"])
    }

    // register([...]) batch registration registers all; registeredKinds()
    // returns the kinds sorted.
    func testBatchRegistrationAndSortedKinds() async {
        let registry = ProposalApplierRegistry()
        await registry.register([
            MockApplier(kind: "upload", id: 1),
            MockApplier(kind: "download", id: 2),
            MockApplier(kind: "mutate", id: 3)
        ])

        let uploadFound = await registry.applier(for: "upload")
        let downloadFound = await registry.applier(for: "download")
        let mutateFound = await registry.applier(for: "mutate")
        XCTAssertNotNil(uploadFound)
        XCTAssertNotNil(downloadFound)
        XCTAssertNotNil(mutateFound)

        let kinds = await registry.registeredKinds()
        XCTAssertEqual(kinds, ["download", "mutate", "upload"])
    }

    // Fire concurrent register and applier(for:) tasks against the actor and
    // assert no data race / consistent final state. The actor serialises all
    // mutations, so after the storm exactly the registered kinds are present.
    func testConcurrentRegisterAndLookup() async {
        let registry = ProposalApplierRegistry()
        let count = 200

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    await registry.register(MockApplier(kind: "kind-\(i)", id: i))
                }
                group.addTask {
                    // Interleave lookups during the writes. Result may be nil
                    // or non-nil depending on timing — we only require that the
                    // call completes without tripping the concurrency checker.
                    _ = await registry.applier(for: "kind-\(i)")
                }
            }
        }

        let kinds = await registry.registeredKinds()
        XCTAssertEqual(kinds.count, count)
        let expected = (0..<count).map { "kind-\($0)" }.sorted()
        XCTAssertEqual(kinds, expected)

        // Every registered kind resolves, and identity matches what we wrote.
        for i in 0..<count {
            let found = await registry.applier(for: "kind-\(i)")
            let resolved = found as? MockApplier
            XCTAssertEqual(resolved?.id, i)
        }
    }

    // applier(for:) returns the proposal-applicable instance whose apply()
    // can be invoked — guards the dispatch contract the strip relies on.
    func testResolvedApplierAppliesProposal() async throws {
        let registry = ProposalApplierRegistry()
        await registry.register(MockApplier(kind: "download", id: 7))

        let applier = await registry.applier(for: "download")
        XCTAssertNotNil(applier)
        // apply() must not throw for the mock; proves the resolved instance
        // is usable for the Apply path.
        try await applier?.apply(makeProposal(kind: "download"))
    }
}
