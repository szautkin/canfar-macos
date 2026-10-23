// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// The Portal's Needs attention on iPhone and iPad (plan 47 1.2): only what
/// needs the person, most pressing first.
final class PortalAttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ status: String, startedAgo: TimeInterval = 3600,
                         expiresIn: TimeInterval? = 7200) -> PortalAttention.SessionFacts {
        PortalAttention.SessionFacts(id: id, name: "nb-\(id)", status: status,
                                     started: now.addingTimeInterval(-startedAgo),
                                     expires: expiresIn.map { now.addingTimeInterval($0) })
    }

    private func items(signedIn: Bool = true, sessions: [PortalAttention.SessionFacts] = [],
                       jobs: [PortalAttention.JobFacts] = [], seen: Set<String> = [],
                       compute: String? = nil, storage: Double? = nil) -> [PortalAttention.Item] {
        PortalAttention.items(signedIn: signedIn, sessions: sessions, jobs: jobs, seenFailedJobs: seen,
                              computeProblem: compute, storagePercent: storage, now: now)
    }

    func testAllWellIsNothing() {
        XCTAssertEqual(items(sessions: [session("a", "Running")],
                             jobs: [.init(id: "j", name: "reduce", status: "Completed")], storage: 50), [])
    }

    func testSignedOutIsTheOnlyThing() {
        let all = items(signedIn: false, sessions: [session("a", "Failed")], storage: 99)
        XCTAssertEqual(all.map(\.kind), [.signIn])
    }

    func testExpiringWithinTheHourSoonestFirst() {
        let all = items(sessions: [session("late", "Running", expiresIn: 50 * 60),
                                   session("soon", "Running", expiresIn: 10 * 60),
                                   session("fine", "Running", expiresIn: 3 * 3600),
                                   session("gone", "Running", expiresIn: -60)])
        XCTAssertEqual(all.map(\.kind), [.sessionExpiring, .sessionExpiring])
        XCTAssertEqual(all.map(\.subjectID), ["soon", "late"])
    }

    func testAPendingSessionIsStuckAfterTenMinutes() {
        let all = items(sessions: [session("new", "Pending", startedAgo: 5 * 60, expiresIn: nil),
                                   session("old", "Pending", startedAgo: 15 * 60, expiresIn: nil)])
        XCTAssertEqual(all.map(\.kind), [.sessionStuck])
        XCTAssertEqual(all.first?.subjectID, "old")
    }

    func testAFailedJobIsNewsOnce() {
        let jobs: [PortalAttention.JobFacts] = [.init(id: "1", name: "a", status: "Failed"),
                                                .init(id: "2", name: "b", status: "Error"),
                                                .init(id: "3", name: "c", status: "Running")]
        XCTAssertEqual(items(jobs: jobs).map(\.subjectID), ["1", "2"])
        XCTAssertEqual(items(jobs: jobs, seen: ["1"]).map(\.subjectID), ["2"])
    }

    func testTheOrderIsMostPressingFirst() {
        let all = items(sessions: [session("x", "Failed"), session("y", "Running", expiresIn: 600)],
                        jobs: [.init(id: "j", name: "j", status: "Failed")],
                        compute: "The image cannot be pulled", storage: 95)
        XCTAssertEqual(all.map(\.kind), [.sessionFailed, .sessionExpiring, .jobFailed, .compute, .storageFull])
    }

    func testStorageFromNinetyPercent() {
        XCTAssertEqual(items(storage: 89.4).map(\.kind), [])
        XCTAssertEqual(items(storage: 90).map(\.kind), [.storageFull])
    }

    func testIDsAreDistinctPerSubject() {
        let all = items(sessions: [session("a", "Failed"), session("b", "Failed")])
        XCTAssertEqual(Set(all.map(\.id)).count, 2)
    }
}
