// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest

/// Compute's runs, read back from /arc (plan 47 2.2): paired by their files,
/// newest first, and merged with this device's own.
final class ComputeRunItemsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ name: String, _ minutes: Double) -> ComputeRunItems.ArcFile {
        .init(name: name, modified: t0.addingTimeInterval(minutes * 60))
    }

    func testFilesPairByIDNewestFirst() {
        let listings = ComputeRunItems.listings(
            out: [file("a.json", 10), file("b.json", 30), file("c.json.partial", 40), file("notes.txt", 50)],
            done: [file("a.json", 11), file("b.json", 31), file("old.json", 1)],
            inbox: [file("new.json", 45), file("b.json", 29)],
            limit: 10)
        XCTAssertEqual(listings.map(\.id), ["new", "b", "a", "old"], "a .partial result is not whole yet")
        XCTAssertEqual(listings.first { $0.id == "new" }?.isWaiting, true)
        XCTAssertEqual(listings.first { $0.id == "b" }?.isWaiting, false, "it has its result")
        XCTAssertEqual(listings.first { $0.id == "old" }?.hasResult, false)
        XCTAssertEqual(listings.first { $0.id == "a" }?.hasRequest, true)
    }

    func testOnlyTheNewestAreRead() {
        let out = (0..<40).map { file("r\($0).json", Double($0)) }
        let listings = ComputeRunItems.listings(out: out, done: [], inbox: [], limit: 25)
        XCTAssertEqual(listings.count, 25)
        XCTAssertEqual(listings.first?.id, "r39")
    }

    func testARunReadsItsRequestAndItsResult() throws {
        let request = try JSONDecoder().decode(RunCodeContract.Request.self, from: Data("""
        {"id":"a","language":"python","code":"import numpy\\nprint(1)","timeout_seconds":60}
        """.utf8))
        let result = try JSONDecoder().decode(RunCodeContract.ResultFile.self, from: Data("""
        {"id":"a","status":"OK","exit_code":0,"stdout":"\(Data("1\n".utf8).base64EncodedString())","stdout_encoding":"base64",
         "duration_ms":1234,"finished_at":"2027-01-15T09:30:00Z"}
        """.utf8))
        let listing = ComputeRunItems.Listing(id: "a", hasResult: true, hasRequest: true, isWaiting: false, modified: t0)
        let item = ComputeRunItems.item(listing, request: request, result: result)
        XCTAssertEqual(item.status, "ok")
        XCTAssertEqual(item.stdout, "1\n", "base64 output decoded")
        XCTAssertEqual(item.firstLine, "import numpy")
        XCTAssertTrue(item.isFinished)
        XCTAssertFalse(item.isFailure)
        XCTAssertNotEqual(item.date, t0, "finished_at, not the file's date")
    }

    func testThisDevicesRunsAreMarkedAndThoseNotOnArcYetAdded() {
        var mine = ComputeRun(RunCodeContract.Request(id: "B", language: "bash", code: "ls", timeout_seconds: 30),
                              author: .user, submittedAt: t0.addingTimeInterval(120))
        mine.status = nil
        let sentHere = ComputeRun(RunCodeContract.Request(id: "a", language: "python", code: "x", timeout_seconds: 30),
                                  author: .user, submittedAt: t0)
        var onArc = ComputeRunItem(id: "a")
        onArc.date = t0.addingTimeInterval(60)
        var elsewhere = ComputeRunItem(id: "z")
        elsewhere.date = t0.addingTimeInterval(10)
        let merged = ComputeRunItems.merge(arc: [onArc, elsewhere], local: [mine, sentHere])
        XCTAssertEqual(merged.map(\.id), ["b", "a", "z"], "newest first; ids as their files are named")
        XCTAssertEqual(merged.map(\.fromThisDevice), [true, true, false])
        XCTAssertEqual(merged.first?.status, ComputeRun.running)
        XCTAssertFalse(merged.first?.isFinished ?? true)
    }
}

/// The FITS files a run's output names in the person's home (plan 47 2.6).
final class ComputeRunOutputFilesTests: XCTestCase {
    func testHomePathsOnceEachInOrder() {
        let out = """
        wrote /arc/home/szautkin/out/m31.fits (4096x4096)
        and ~/cubes/ngc2403.fits.fz, then /arc/home/szautkin/out/m31.fits again
        not /arc/home/someoneelse/x.fits, nor /arc/projects/p/y.fits, nor ../../etc.fits
        'quoted': /arc/home/szautkin/a b/notes.txt
        """
        XCTAssertEqual(ComputeRunItems.homeFITSPaths(in: out, username: "szautkin"),
                       ["out/m31.fits", "cubes/ngc2403.fits.fz"])
    }

    func testNoneWithoutAUser() {
        XCTAssertEqual(ComputeRunItems.homeFITSPaths(in: "~/a.fits", username: ""), [])
    }
}
