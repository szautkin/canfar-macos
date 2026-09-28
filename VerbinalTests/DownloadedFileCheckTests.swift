// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// A download that holds nothing is refused as it lands and flagged when
/// found in Research — the 0-byte packages and 1024-byte empty tars the QA
/// pass found kept as downloads.
final class DownloadedFileCheckTests: XCTestCase {

    private var files: [URL] = []

    override func tearDown() {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func file(_ bytes: Data, _ name: String = "f") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try bytes.write(to: url)
        files.append(url)
        return url
    }

    func testNothingIsCaughtInEachOfItsForms() throws {
        XCTAssertEqual(DownloadedFileCheck.problem(at: try file(Data(), "pkg.txt")), .empty)
        XCTAssertEqual(DownloadedFileCheck.problem(at: try file(Data(count: 1024), "noao.tar")), .emptyArchive, "tar's end marker alone")
        XCTAssertEqual(DownloadedFileCheck.problem(at: try file(Data(count: 10240), "x.tar")), .emptyArchive, "padded to a record")
        XCTAssertEqual(DownloadedFileCheck.problem(at: try file(Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)), "e.zip")),
                       .emptyArchive)
        XCTAssertEqual(DownloadedFileCheck.problem(at: FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID())")),
                       .missing)
        XCTAssertEqual(DownloadedFileCheck.problem(at: try file(Data(count: 100)), expectedBytes: 4096), .shortOf(expected: 4096, got: 100))
    }

    func testSomethingPasses() throws {
        var fits = Data("SIMPLE  =                    T".utf8)
        fits.append(Data(count: 2880 - fits.count))
        XCTAssertNil(DownloadedFileCheck.problem(at: try file(fits, "a.fits"), expectedBytes: 2880))
        var tar = Data("member.fits".utf8)
        tar.append(Data(count: 2048 - tar.count))
        XCTAssertNil(DownloadedFileCheck.problem(at: try file(tar, "a.tar")), "a tar with a member")
        XCTAssertNil(DownloadedFileCheck.problem(at: try file(Data(count: 20480), "zeros.bin")), "zeros too big to be an empty tar")
    }

    func testAResearchRecordSaysWhatIsWrongWithItsFile() throws {
        let empty = try file(Data(count: 1024), "pkg.tar")
        var record = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/NOAO?x/y", collection: "NOAO", observationID: "x",
                                           targetName: "", instrument: "", filter: "", ra: "", dec: "", startDate: "",
                                           calLevel: "", localPath: empty.path)
        XCTAssertEqual(record.fileProblem, .emptyArchive)
        XCTAssertNotNil(record.fileProblem?.message)
        record = record.withoutFile()
        XCTAssertNil(record.fileProblem, "no file kept, nothing to judge")
    }

    /// As a download lands: an empty tar from the server is refused, not kept.
    func testAnEmptyArchiveIsRefusedAsItLands() async throws {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "1024"])!, Data(count: 1024))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let service = DownloadService(session: MockURLProtocol.mockSession(), tasks: TaskRegistry())
        do {
            _ = try await service.downloadToTemp(url: URL(string: "https://example.invalid/pkg")!, suggestedFilename: "pkg.tar",
                                                 publisherID: "ivo://cadc.nrc.ca/NOAO?x/y")
            XCTFail("an empty archive is not a download")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("empty archive"), error.localizedDescription)
        }
    }
}
