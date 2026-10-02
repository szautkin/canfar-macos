// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// Plan 30 A: what an assistant may do without asking, kind by kind.
final class ChangeKindTests: XCTestCase {

    /// The person's decisions (A0): what adds goes ahead but sharing; what
    /// removes asks but what an assistant made; batch jobs allowed.
    func testTheDefaultsAreThePersonsDecisions() {
        let allowed = Set(ChangeKind.allCases.filter { ChangePermissions.defaults.allows($0) })
        XCTAssertEqual(allowed, [.notesAndSaved, .filesOnMac, .addToStorage, .allocationSessions, .allocationBatch,
                                 .removeAssistantMade])
        XCTAssertTrue(ChangePermissions.defaults.isDefault)
    }

    func testDestructiveIsWhatRemovesReplacesOrStops() {
        let destructive = Set(ChangeKind.allCases.filter(\.isDestructive))
        XCTAssertEqual(destructive, [.removeAssistantMade, .removeNotesAndSaved, .removeFilesOnMac, .removeFromStorage,
                                     .stopWork, .everythingAtOnce])
    }

    /// What every later assistant is told always waits: it cannot be allowed.
    func testStandingInstructionsAlwaysWait() {
        var permissions = ChangePermissions.defaults
        permissions.set(.standingInstruction, allowed: true)
        XCTAssertFalse(permissions.allows(.standingInstruction))
        XCTAssertFalse(ChangeKind.standingInstruction.isSettable)
        XCTAssertTrue(AutoApplyPolicy.rule(forChange: .standingInstruction, appliedAtOnce: false).contains("always waits"))
    }

    func testEachKindAppliesOrWaitsAsThePersonSets() {
        var permissions = ChangePermissions.defaults
        permissions.set(.stopWork, allowed: true)
        permissions.set(.notesAndSaved, allowed: false)
        XCTAssertTrue(AutoApplyPolicy.appliesAtOnce(.stopWork, permissions: permissions))
        XCTAssertFalse(AutoApplyPolicy.appliesAtOnce(.notesAndSaved, permissions: permissions))
        XCTAssertFalse(permissions.isDefault)
        XCTAssertEqual(AutoApplyPolicy.rule(forChange: .stopWork, appliedAtOnce: true),
                       "applied at once: the person allows \"Stop running work on CANFAR\"")
        XCTAssertEqual(AutoApplyPolicy.rule(forChange: .notesAndSaved, appliedAtOnce: false),
                       "waits in Pending: the person asks to approve \"Notes and saved things on this Mac\"")
        XCTAssertTrue(AutoApplyPolicy.toolSentence(forChange: .stopWork, permissions: permissions).contains("(destructive)"))
        XCTAssertTrue(AutoApplyPolicy.toolSentence(forChange: .notesAndSaved, permissions: permissions).contains("waits in Pending"))
    }

    /// The old Auto-apply switch: on is the defaults, off asks for everything.
    func testTheOldSwitchMapsOntoTheKinds() {
        XCTAssertEqual(ChangePermissions.migrating(autoApplyOn: true), .defaults)
        let off = ChangePermissions.migrating(autoApplyOn: false)
        XCTAssertTrue(ChangeKind.allCases.allSatisfy { !off.allows($0) })
    }

    func testTheSettingsRoundTrip() throws {
        var permissions = ChangePermissions.defaults
        permissions.set(.sharing, allowed: true)
        permissions.set(.removeAssistantMade, allowed: false)
        let read = try JSONDecoder().decode(ChangePermissions.self, from: JSONEncoder().encode(permissions))
        XCTAssertEqual(read, permissions)
        XCTAssertTrue(read.allows(.sharing))
        XCTAssertFalse(read.allows(.removeAssistantMade))
        permissions.set(.sharing, allowed: false)
        permissions.set(.removeAssistantMade, allowed: true)
        XCTAssertEqual(permissions, .defaults, "setting a kind back to its default leaves nothing behind")
    }
}
