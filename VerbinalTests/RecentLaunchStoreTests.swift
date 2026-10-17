// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

@MainActor
final class RecentLaunchStoreTests: XCTestCase {

    private func makeStore() -> RecentLaunchStore {
        RecentLaunchStore()
    }

    private func makeLaunch(name: String, type: String = "notebook", image: String = "images.canfar.net/skaha/notebook:latest") -> RecentLaunch {
        RecentLaunch(
            name: name,
            type: type,
            image: image,
            imageLabel: "notebook:latest",
            project: "skaha",
            resourceType: "flexible",
            cores: 0,
            ram: 0,
            gpus: 0,
            launchedAt: Date()
        )
    }

    func testSaveDedupsByName() {
        let store = makeStore()
        store.clear()

        store.save(makeLaunch(name: "notebook1"))
        store.save(makeLaunch(name: "notebook2"))
        store.save(makeLaunch(name: "notebook1")) // duplicate name

        XCTAssertEqual(store.launches.count, 2)
        XCTAssertEqual(store.launches[0].name, "notebook1") // most recent first
        XCTAssertEqual(store.launches[1].name, "notebook2")
    }

    func testSameTypeAndImageDifferentNameCreatesMultipleEntries() {
        let store = makeStore()
        store.clear()

        let image = "images.canfar.net/skaha/notebook:latest"
        store.save(makeLaunch(name: "notebook1", type: "notebook", image: image))
        store.save(makeLaunch(name: "notebook2", type: "notebook", image: image))
        store.save(makeLaunch(name: "notebook3", type: "notebook", image: image))

        XCTAssertEqual(store.launches.count, 3)
    }

    func testSaveTrimsToMaxEntries() {
        let store = makeStore()
        store.clear()

        for i in 1...12 {
            store.save(makeLaunch(name: "session\(i)"))
        }

        XCTAssertEqual(store.launches.count, 10) // max 10
        XCTAssertEqual(store.launches[0].name, "session12") // most recent first
    }

    func testRemoveDeletesEntry() {
        let store = makeStore()
        store.clear()

        store.save(makeLaunch(name: "nb1"))
        store.save(makeLaunch(name: "nb2"))

        let toRemove = store.launches.first { $0.name == "nb1" }!
        store.remove(toRemove)

        XCTAssertEqual(store.launches.count, 1)
        XCTAssertEqual(store.launches[0].name, "nb2")
    }

    func testClearRemovesAll() {
        let store = makeStore()
        store.save(makeLaunch(name: "nb1"))
        store.save(makeLaunch(name: "nb2"))

        store.clear()

        XCTAssertTrue(store.launches.isEmpty)
    }

    // MARK: - One list (the live check of plan 42, 2026-10-16)

    /// list_recent_launches had a list of its own, read once when the tools
    /// were made: it missed the session the person had just launched, which
    /// the Recent Launches card showed.
    func testListRecentLaunchesHasWhatTheFormJustSaved() async throws {
        let app = AppState()
        let tool = try XCTUnwrap(app.makeAgentTools().compactMap { $0 as? ListRecentLaunchesTool }.first)
        let name = "one-list-\(UUID().uuidString.prefix(8))"
        app.recentLaunchStore.save(makeLaunch(name: name))
        defer { app.recentLaunchStore.launches.filter { $0.name == name }.forEach { app.recentLaunchStore.remove($0) } }
        let context = AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))
        let listed = try await tool.handle(EmptyArgs(), context: context)
        XCTAssertEqual(listed.entries.first?.name, name)
    }

    /// A row says the GPUs its launch asked for, as its session's card does.
    func testARowSaysItsGPUs() {
        var launch = makeLaunch(name: "nb")
        launch.resourceType = "fixed"
        launch.cores = 1
        launch.ram = 4
        XCTAssertEqual(RecentLaunchesView.resources(of: launch), "CPU: 1 · RAM: 4 GB")
        launch.gpus = 1
        XCTAssertEqual(RecentLaunchesView.resources(of: launch), "CPU: 1 · RAM: 4 GB · GPU: 1")
        launch.resourceType = "flexible"
        XCTAssertEqual(RecentLaunchesView.resources(of: launch), "Flexible")
    }
}
