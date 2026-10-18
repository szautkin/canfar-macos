// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Plan 46 M1: what the Move To sheet does to each of the active record's
/// files, for every case of where they are.
final class MoveToPlanTests: XCTestCase {
    private let mac = FilePlaces(onMac: true, inStorage: false)
    private let storage = FilePlaces(onMac: false, inStorage: true)
    private let both = FilePlaces(onMac: true, inStorage: true)

    private func file(_ name: String, _ places: FilePlaces, size: Int64 = 1_000, readable: Bool = true) -> MoveToPlan.File {
        MoveToPlan.File(name: name, size: size, places: places, onMacReadable: readable)
    }

    func testOnThisMacOnlyCopiesToStorage() {
        let plan = MoveToPlan(files: [file("c.fits", mac)], signedIn: true)
        XCTAssertEqual(plan.to, .storage)
        XCTAssertEqual(plan.rows.first?.step, .copy(to: .storage))
        XCTAssertEqual(plan.rows.first?.after, both, "after: in both places")
        XCTAssertEqual(plan.buttonTitle, "Copy to Storage")
        XCTAssertFalse(plan.removes)
        XCTAssertEqual(plan.toStorage, 1_000)
        XCTAssertTrue(plan.canRun)
    }

    func testInStorageOnlyCopiesToThisMac() {
        let plan = MoveToPlan(files: [file("c.fits", storage)], signedIn: true)
        XCTAssertEqual(plan.to, .mac)
        XCTAssertEqual(plan.rows.first?.step, .copy(to: .mac))
        XCTAssertEqual(plan.buttonTitle, "Copy to This Mac")
        XCTAssertEqual(plan.toMac, 1_000)
    }

    func testAMoveRemovesTheCopyItLeaves() {
        var plan = MoveToPlan(files: [file("c.fits", mac)], signedIn: true)
        plan.keepCopy = false
        XCTAssertEqual(plan.rows.first?.step, .move(to: .storage))
        XCTAssertEqual(plan.rows.first?.after, storage)
        XCTAssertEqual(plan.buttonTitle, "Move to Storage")
        XCTAssertTrue(plan.removes)
        XCTAssertTrue(plan.summary.contains("The copy on this Mac is removed once the one in your storage is there."), "\(plan.summary)")
        XCTAssertEqual(plan.warnings, ["The copy on this Mac is removed once the one in your storage is there."],
                       "what moves is said quietly; what is removed, as a warning")
    }

    /// Every file in both places: which copy to keep — storage, by default.
    func testInBothPlacesKeepsOne() {
        var plan = MoveToPlan(files: [file("c.fits", both)], signedIn: true)
        XCTAssertTrue(plan.isKeepOnly)
        XCTAssertEqual(plan.to, .storage)
        XCTAssertEqual(plan.rows.first?.step, .remove(from: .mac))
        XCTAssertEqual(plan.buttonTitle, "Remove from This Mac")
        XCTAssertTrue(plan.summary.contains("The copy on this Mac is removed; the one in your storage stays."), "\(plan.summary)")
        plan.to = .mac
        XCTAssertEqual(plan.rows.first?.step, .remove(from: .storage))
        XCTAssertEqual(plan.buttonTitle, "Remove from Storage")
    }

    /// A cutout with its weight map, one already in storage: only the other goes.
    func testSeveralFilesEachAsItIs() {
        let plan = MoveToPlan(files: [file("c.fits", mac), file("w.fits", both)], signedIn: true)
        XCTAssertFalse(plan.isKeepOnly)
        XCTAssertEqual(plan.rows.map(\.step), [.copy(to: .storage), nil])
        XCTAssertEqual(plan.rows.map(\.held), [nil, .alreadyThere])
        XCTAssertEqual(plan.rows.map(\.checked), [true, false])
        XCTAssertEqual(plan.buttonTitle, "Copy to Storage")

        var moving = plan
        moving.keepCopy = false
        XCTAssertEqual(moving.rows.map(\.step), [.move(to: .storage), .remove(from: .mac)],
                       "a move leaves every file in storage only")
        XCTAssertEqual(moving.buttonTitle, "Move 2 Files to Storage")
    }

    func testTheCountAndTheUncheckedFile() {
        var plan = MoveToPlan(files: [file("a.fits", mac), file("b.fits", mac)], signedIn: true)
        XCTAssertEqual(plan.buttonTitle, "Copy 2 Files to Storage")
        plan.unchecked = ["b.fits"]
        XCTAssertEqual(plan.buttonTitle, "Copy to Storage")
        XCTAssertEqual(plan.rows.last?.after, mac, "an unchecked file stays as it is")
        plan.keepCopy = false
        XCTAssertEqual(plan.rows.last?.checked, false, "still unchecked after the choice changes")
        plan.unchecked = ["a.fits", "b.fits"]
        XCTAssertFalse(plan.canRun)
        XCTAssertEqual(plan.summary, ["Nothing to move."])
    }

    func testAFileGoneFromThisMacIsHeld() {
        let plan = MoveToPlan(files: [file("c.fits", mac, readable: false)], signedIn: true)
        XCTAssertEqual(plan.rows.first?.held, .notOnMac)
        XCTAssertFalse(plan.canRun)
    }

    func testARefusalIsShownOnItsFile() {
        let plan = MoveToPlan(files: [file("c.fits", mac)], signedIn: true,
                              refused: ["c.fits": "A different file is in your storage at x already."])
        XCTAssertEqual(plan.rows.first?.held, .refused("A different file is in your storage at x already."))
        XCTAssertFalse(plan.canRun)
    }

    func testSignedOutNothingRuns() {
        let plan = MoveToPlan(files: [file("c.fits", mac)], signedIn: false)
        XCTAssertFalse(plan.canRun)
        XCTAssertEqual(plan.summary, ["Sign in to CANFAR to move files to and from your storage"])
    }

    func testStorageWithoutRoomStopsTheButton() {
        var plan = MoveToPlan(files: [file("c.fits", mac, size: 5_000)], signedIn: true, free: 4_000)
        XCTAssertFalse(plan.fits)
        XCTAssertFalse(plan.canRun)
        XCTAssertTrue(plan.summary.contains("There is not enough room in your storage for it."), "\(plan.summary)")
        plan.free = 10_000
        XCTAssertTrue(plan.canRun)
    }

    /// Toward this Mac, a file only on this Mac is there already.
    func testTowardWhereAFileIsNothingGoes() {
        var plan = MoveToPlan(files: [file("c.fits", mac)], signedIn: true)
        plan.to = .mac
        XCTAssertEqual(plan.rows.first?.held, .alreadyThere)
        XCTAssertFalse(plan.canRun)
    }

    /// Only the active record: a cutout's files are its own.
    func testACutoutsFilesAreItsOwn() {
        var cutout = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?745234/745234p", collection: "CFHT",
                                           observationID: "745234", targetName: "D2", instrument: "", filter: "", ra: "",
                                           dec: "", startDate: "", calLevel: "", localPath: "/tmp/745234p.cutout-1.fits")
        cutout.fileSize = 124
        cutout.storagePath = "Verbinal-Results/research/745234p.cutout-1.fits"
        let files = MoveToPlan.files(of: cutout)
        XCTAssertEqual(files.map(\.name), ["745234p.cutout-1.fits"])
        XCTAssertEqual(files.first?.places, both)
    }
}
