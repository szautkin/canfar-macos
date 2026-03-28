// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

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
}
