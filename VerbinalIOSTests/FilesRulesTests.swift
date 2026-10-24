// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// Files' rules and words (plan 48): what is suggested for deletion, the
/// cap, folder names, what every confirmation says, and the menu as data.
final class FilesRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ kind: LocalFileKind, days: Double, inStorage: Bool = true, size: Int64 = 1_000) -> LocalFile {
        LocalFile(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"), kind: kind, size: size,
                  lastOpened: now.addingTimeInterval(-days * 86_400),
                  origin: inStorage ? FileOrigin(storagePath: "out/a.fits") : nil)
    }

    // MARK: - Rules

    func testStaleIsDownloadsAndReceivedNotOpenedInThirtyDays() {
        let old = file(.downloads, days: 31), recent = file(.downloads, days: 29)
        let oldReceived = file(.received, days: 60, inStorage: false), oldKept = file(.kept, days: 90)
        XCTAssertEqual(FilesRules.stale([old, recent, oldReceived, oldKept], now: now), [old, oldReceived],
                       "kept files were kept on purpose")
    }

    func testTheCapIsAChoiceElseTheDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FilesRulesTests-\(UUID().uuidString)"))
        XCTAssertEqual(FilesRules.capGB(defaults), 2)
        defaults.set(5, forKey: FilesRules.capKey)
        XCTAssertEqual(FilesRules.capGB(defaults), 5)
        XCTAssertEqual(FilesRules.capBytes(defaults), 5 * 1024 * 1024 * 1024)
        defaults.set(3, forKey: FilesRules.capKey)
        XCTAssertEqual(FilesRules.capGB(defaults), 2, "not one of the choices")
    }

    func testAFolderNameHasNoSlashAndIsNotDots() {
        XCTAssertTrue(FilesRules.isValidName("reduced"))
        XCTAssertTrue(FilesRules.isValidName("  night 2  "))
        for bad in ["", "   ", "a/b", ".", ".."] { XCTAssertFalse(FilesRules.isValidName(bad), bad) }
    }

    // MARK: - Words

    func testDeletingSaysWhetherStorageStillHasThem() {
        let inStorage = file(.downloads, days: 1), notInStorage = file(.received, days: 1, inStorage: false)
        XCTAssertEqual(FilesWording.deleteMeaning([inStorage]), "It stays in your storage; only this device's copy goes.")
        XCTAssertEqual(FilesWording.deleteMeaning([inStorage, inStorage]),
                       "They stay in your storage; only this device's copies go.")
        XCTAssertEqual(FilesWording.deleteMeaning([notInStorage]),
                       "It is not in your storage, so Verbinal cannot download it again.")
        XCTAssertEqual(FilesWording.deleteMeaning([inStorage, notInStorage, notInStorage]),
                       "2 of them are not in your storage, so Verbinal cannot download them again; the rest stay there.")
    }

    func testTheTitleNamesHowManyAndHowMuch() {
        let title = FilesWording.deleteTitle([file(.downloads, days: 1, size: 2_000_000), file(.kept, days: 1, size: 1_000_000)])
        XCTAssertTrue(title.hasPrefix("Delete 2 files ("), title)
        XCTAssertTrue(title.contains(FilesWording.bytes(3_000_000)), title)
        XCTAssertTrue(FilesWording.deleteTitle([file(.kept, days: 1)]).hasPrefix("Delete 1 file ("))
    }

    func testDeletingFromStorageSaysWhatGoesAndThatItCannotBeUndone() {
        let undo = "This cannot be undone: storage has no trash."
        XCTAssertEqual(FilesWording.storageDeleteMeaning(isFolder: false, items: nil),
                       "It is deleted from your storage. " + undo)
        XCTAssertEqual(FilesWording.storageDeleteMeaning(isFolder: true, items: 12),
                       "It holds 12 items, all deleted with it. " + undo)
        XCTAssertEqual(FilesWording.storageDeleteMeaning(isFolder: true, items: 1),
                       "It holds 1 item, deleted with it. " + undo)
        XCTAssertEqual(FilesWording.storageDeleteMeaning(isFolder: true, items: 0), "It is empty. " + undo)
        XCTAssertEqual(FilesWording.storageDeleteMeaning(isFolder: true, items: nil),
                       "Everything in it is deleted with it. " + undo)
        XCTAssertEqual(FilesWording.storageDeleteMeaning(isFolder: true, items: 500),
                       "It holds 500 items or more, all deleted with it. " + undo, "a listing stops at its limit")
        XCTAssertEqual(FilesWording.storageDeleteTitle(name: "raw"), "Delete “raw”?")
    }

    // MARK: - The menu

    func testEveryMenuEntryIsInTheMenuOnceInItsSectionsOrder() {
        let signedIn = iOSMenuEntry.layout(signedIn: true), signedOut = iOSMenuEntry.layout(signedIn: false)
        for layout in [signedIn, signedOut] {
            let entries = layout.flatMap(\.entries)
            XCTAssertEqual(entries.count, Set(entries).count, "no entry twice")
        }
        XCTAssertEqual(Set(signedIn.flatMap(\.entries) + signedOut.flatMap(\.entries)), Set(iOSMenuEntry.allCases))
        XCTAssertEqual(signedIn.map(\.section), iOSMenuEntry.Section.allCases)
        XCTAssertEqual(signedIn.first?.entries, [.onThisDevice, .yourStorage], "Files first")
        XCTAssertEqual(signedIn.last?.entries, [.signOut], "Sign Out last")
    }

    /// Plan 49: signed out, Sign In comes first and the rest is the same menu.
    func testSignedOutTheMenuStartsWithSignIn() {
        let signedIn = iOSMenuEntry.layout(signedIn: true), signedOut = iOSMenuEntry.layout(signedIn: false)
        XCTAssertEqual(signedOut.first?.section, .account)
        XCTAssertEqual(signedOut.first?.entries, [.signIn])
        XCTAssertEqual(signedOut.dropFirst().map(\.entries), signedIn.dropLast().map(\.entries))
    }

    /// Plan 49: what needs the CANFAR account is locked signed out; the files
    /// on the device, the cap, help and Sign In are not.
    func testWhatNeedsTheAccount() {
        let needing = Set(iOSMenuEntry.allCases.filter(\.needsAccount))
        XCTAssertEqual(needing, [.yourStorage, .reminders, .aiCompute, .signOut])
        XCTAssertFalse(iOSMenuEntry.signIn.needsAccount)
        XCTAssertFalse(iOSMenuEntry.onThisDevice.needsAccount)
    }
}
