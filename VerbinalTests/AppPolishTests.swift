// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// The agent's two sounds, and what About tells a bug report.
@MainActor
final class AppPolishTests: XCTestCase {

    // MARK: - Sound cues

    func testOnlyTheEdgesOfABurstAreHeard() {
        var tracker = AgentCueTracker()
        XCTAssertEqual(tracker.activity(), .started)
        XCTAssertNil(tracker.activity(), "a call among many is not a cue")
        XCTAssertNil(tracker.activity())
        XCTAssertEqual(tracker.idle(), .finished)
        XCTAssertNil(tracker.idle(), "quiet once, not again")
        XCTAssertEqual(tracker.activity(), .started)
    }

    func testABurstOfCallsIsOneStartAndOneStop() async throws {
        var heard: [AgentCue] = []
        let sounds = AgentSounds(enabledOverride: true) { heard.append($0) }
        for _ in 0..<5 { sounds.agentCalled() }
        XCTAssertEqual(heard, [.started])
        try await Task.sleep(for: AgentSounds.quietAfter + .milliseconds(400))
        XCTAssertEqual(heard, [.started, .finished])

        heard = []
        sounds.isEnabled = false
        sounds.agentCalled()
        XCTAssertTrue(heard.isEmpty, "switched off, it is quiet — at once")
    }

    func testEveryCueHasItsSoundInTheApp() {
        for cue in AgentCue.allCases {
            XCTAssertNotNil(Bundle.main.url(forResource: cue.fileName, withExtension: "wav"), cue.fileName)
        }
    }

    // MARK: - About

    func testRuntimeFactsAreAllThereAsPastableText() {
        let facts = RuntimeInfo.facts()
        XCTAssertEqual(facts.map(\.name), ["App", "OS", "Machine", "Architecture", "GPU", "Memory", "Install"])
        XCTAssertTrue(facts.allSatisfy { !$0.value.isEmpty }, "a value that cannot be read says so")
        XCTAssertEqual(RuntimeInfo.text([.init(name: "App", value: "1.4.0 (14)"), .init(name: "OS", value: "macOS 26")]),
                       "App: 1.4.0 (14)\nOS: macOS 26")
        XCTAssertEqual(RuntimeInfo.appVersion(["CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "14"]), "1.4.0 (14)")
        XCTAssertEqual(RuntimeInfo.appVersion([:]), "unknown")
    }
}
