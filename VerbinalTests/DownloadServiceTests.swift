// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 005: DownloadService's actor-isolated file helpers (`fileSize`,
/// `deleteFile`). (Ticket 006 extends this suite with DataLink-fallback and
/// filename-extraction tests.)
final class DownloadServiceTests: XCTestCase {

    func testFileSizeReturnsByteCount() async throws {
        let service = DownloadService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-size-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: 1234).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let size = await service.fileSize(at: url)
        XCTAssertEqual(size, 1234)
    }

    func testFileSizeNilForMissingFile() async {
        let service = DownloadService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-missing-\(UUID().uuidString).bin")
        let size = await service.fileSize(at: url)
        XCTAssertNil(size)
    }

    func testDeleteFileRemovesThenIsIdempotent() async throws {
        let service = DownloadService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-del-\(UUID().uuidString).bin")
        try Data("x".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try await service.deleteFile(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // A second delete on a now-missing file must not throw.
        try await service.deleteFile(at: url)
    }

    // MARK: - Ticket 051: logged (non-throwing) deletion

    func testDeleteFileLoggingFailureRemovesExistingFileAndReportsSuccess() async throws {
        let service = DownloadService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-log-del-\(UUID().uuidString).bin")
        try Data("x".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let ok = await service.deleteFileLoggingFailure(at: url)
        XCTAssertTrue(ok, "successful deletion reports success")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteFileLoggingFailureIsNoOpForMissingFile() async {
        let service = DownloadService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-log-missing-\(UUID().uuidString).bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // A missing file is a no-op (fileExists guard) and must not throw or
        // report failure — it returns success without logging a warning.
        let ok = await service.deleteFileLoggingFailure(at: url)
        XCTAssertTrue(ok, "deleting a non-existent file is a successful no-op")
    }

    // MARK: - Ticket 006: filename sanitization (path-traversal guard)

    func testSanitizeFilenameStripsPathComponents() {
        XCTAssertEqual(DownloadService.sanitizeFilename("a/b/c.fits"), "c.fits")
        XCTAssertEqual(DownloadService.sanitizeFilename("/etc/passwd"), "passwd")
        XCTAssertEqual(DownloadService.sanitizeFilename("../../etc/passwd"), "passwd")
    }

    func testSanitizeFilenameStripsIllegalCharacters() {
        XCTAssertEqual(DownloadService.sanitizeFilename("x:y.fits"), "xy.fits")
        XCTAssertEqual(DownloadService.sanitizeFilename("na\u{0}me.fits"), "name.fits")
        XCTAssertEqual(DownloadService.sanitizeFilename(#"a\b.fits"#), "ab.fits")
    }

    func testSanitizeFilenameEmpty() {
        XCTAssertEqual(DownloadService.sanitizeFilename(""), "")
    }

    // MARK: - Ticket 006: publisher-id filename derivation + content-type extension

    func testFilenameFromPublisherIDPicksProductAndExtension() {
        XCTAssertEqual(
            DownloadService.filename(fromPublisherID: "ivo://cadc.nrc.ca/CFHT?2376354/2376354p", contentType: "application/fits"),
            "2376354p.fits")
        XCTAssertEqual(
            DownloadService.filename(fromPublisherID: "ivo://cadc.nrc.ca/JWST?obs123/prod456", contentType: "application/x-tar"),
            "prod456.tar")
        XCTAssertEqual(
            DownloadService.filename(fromPublisherID: "ivo://cadc.nrc.ca/JCMT?o/p", contentType: "application/gzip"),
            "p.fits.gz")
    }

    func testFilenameFromPublisherIDNoSlashFallsBackToObservation() {
        // No "/" and no "?" => the literal "observation" base.
        XCTAssertEqual(
            DownloadService.filename(fromPublisherID: "bareid", contentType: "application/octet-stream"),
            "observation")
    }

    // MARK: - Ticket 006: Content-Disposition extraction (with sanitization)

    func testExtractFilenameFromContentDisposition() async {
        let service = DownloadService()
        let resp = HTTPURLResponse(
            url: URL(string: "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/data")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Disposition": #"attachment; filename="../evil/NGC1234.fits""#]
        )!
        // The path-y filename in the header is sanitized to its last component.
        let name = await service.extractFilename(from: resp, publisherID: "ivo://x?y/z")
        XCTAssertEqual(name, "NGC1234.fits")
    }
}
