// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Plan 34 F: a file of an observation downloads into the download folder,
/// Research records it beside the record's main file, and it is removed
/// the same way, one path for the Files tab, Research and an assistant.
@MainActor
final class ResearchFilesTests: XCTestCase {
    private var fileName = ""
    private var folder: URL!
    private var store: ObservationStore!
    private var files: ResearchFiles!
    private var served: [String] = []

    private let publisherID = "ivo://cadc.nrc.ca/CFHT?2388466/2388466p"

    override func setUp() async throws {
        try await super.setUp()
        fileName = "test-research-files-\(UUID().uuidString).json"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never the person's Downloads.
        let downloads = folder
        DownloadsFolder.chosen.withLock { $0 = downloads }
        served = []
        MockURLProtocol.requestHandler = { [weak self] request in
            let name = request.url?.lastPathComponent ?? "file"
            Task { @MainActor in self?.served.append(name) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("SIMPLE  =                    T / \(name)".utf8) + Data(count: 2048))
        }
        store = ObservationStore(fileName: fileName, spotlight: nil)
        files = ResearchFiles(store: store, downloads: DownloadService(session: MockURLProtocol.mockSession(), tasks: TaskRegistry()))
    }

    override func tearDown() {
        DownloadsFolder.chosen.withLock { $0 = nil }
        MockURLProtocol.requestHandler = nil
        try? FileManager.default.removeItem(at: folder)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Verbinal")
        if let dir { try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName)) }
        super.tearDown()
    }

    private func details(localPath: String = "") -> DownloadedObservation {
        DownloadedObservation(publisherID: publisherID, collection: "CFHT", observationID: "2388466", targetName: "M31",
                              instrument: "MegaPrime", filter: "r", ra: "", dec: "", startDate: "", calLevel: "2",
                              localPath: localPath)
    }

    func testAFileOfAnObservationResearchDoesNotKeepMakesItsRecord() async throws {
        var made: [DownloadedObservation] = []
        files.onNewRecord = { made.append($0) }
        let (record, file) = try await files.download(.artifact(uri: "cadc:CFHT/2388466o.fits.fz"), for: details())

        XCTAssertEqual(store.observations.map(\.id), [record.id])
        XCTAssertFalse(record.isDownloaded, "the main file is not this one")
        XCTAssertEqual(record.keptFiles.map(\.name), ["2388466o.fits.fz"])
        XCTAssertEqual(file.uri, "cadc:CFHT/2388466o.fits.fz")
        XCTAssertEqual(URL(fileURLWithPath: file.localPath).deletingLastPathComponent().resolvingSymlinksInPath(),
                       folder.resolvingSymlinksInPath(), "into the download folder")
        XCTAssertTrue(file.local.exists)
        XCTAssertEqual(made.map(\.id), [record.id], "a new record is completed from the archive")
        if case .kept(let kept) = files.state(of: "2388466o.fits.fz", publisherID: publisherID) {
            XCTAssertEqual(kept.name, file.name)
        } else {
            XCTFail("kept")
        }
        XCTAssertEqual(files.state(of: "2388466p.fits.fz", publisherID: publisherID), .notKept)
    }

    func testAFileJoinsTheRecordBesideItsMainFileAndNeverReplacesAFile() async throws {
        let main = folder.appendingPathComponent("2388466p.fits.fz")
        try Data("main".utf8).write(to: main)
        let existing = store.save(details(localPath: main.path))

        let first = try await files.download(.artifact(uri: "cadc:CFHT/2388466o.fits.fz"), for: details())
        let second = try await files.download(.artifact(uri: "cadc:CFHT/2388466p.weight.fits.fz"), for: details())
        XCTAssertEqual(second.record.id, existing.id, "the same record")
        XCTAssertEqual(second.record.localPath, main.path, "its main file stays")
        XCTAssertEqual(Set(second.record.keptFiles.map(\.name)), ["2388466o.fits.fz", "2388466p.weight.fits.fz"])

        // Again: the record keeps one of that name; the folder keeps both.
        let again = try await files.download(.artifact(uri: "cadc:CFHT/2388466o.fits.fz"), for: details())
        XCTAssertEqual(again.record.keptFiles.filter { $0.name == "2388466o.fits.fz" }.count, 1)
        XCTAssertNotEqual(again.file.localPath, first.file.localPath, "never over a file")
        XCTAssertTrue(first.file.local.exists)
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "main")
    }

    func testRemovingAFileDeletesItAndKeepsTheObservation() async throws {
        let (record, file) = try await files.download(.artifact(uri: "cadc:CFHT/2388466o.fits.fz"), for: details())
        _ = try await files.download(.artifact(uri: "cadc:CFHT/2388466p.fits.fz"), for: details())

        let kept = try await files.remove(fileNamed: file.name, of: record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.localPath))
        XCTAssertEqual(kept?.keptFiles.map(\.name), ["2388466p.fits.fz"])
        XCTAssertEqual(store.observations.count, 1, "the observation stays")
        XCTAssertEqual(files.state(of: file.name, publisherID: publisherID), .notKept, "the trash is a download button again")
        let none = try await files.remove(fileNamed: "nothing.fits", of: record.id)
        XCTAssertNil(none)
    }

    func testTheMainFileIsOneOfTheFilesByItsName() async throws {
        let main = folder.appendingPathComponent("2388466p.fits.fz")
        try Data("main".utf8).write(to: main)
        let record = store.save(details(localPath: main.path))
        guard case .kept(let file) = files.state(of: "2388466p.fits.fz", publisherID: publisherID) else { return XCTFail("kept") }
        XCTAssertTrue(file.isMain)

        let kept = try await files.remove(fileNamed: "2388466p.fits.fz", of: record.id)
        XCTAssertEqual(kept?.isDownloaded, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: main.path))
    }

    /// Records kept before 1.4.1 read as they were, and a record's files
    /// survive a reload; the "main" mark is never stored.
    func testRecordsKeptBeforeReadAndFilesSurviveAReload() throws {
        let old = #"[{"id":"\#(UUID().uuidString)","publisherID":"\#(publisherID)","collection":"CFHT","observationID":"2388466","targetName":"M31","instrument":"","filter":"","ra":"","dec":"","startDate":"","calLevel":"","localPath":"","downloadedAt":"2026-10-01T10:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([DownloadedObservation].self, from: Data(old.utf8))
        XCTAssertEqual(records.first?.keptFiles, [])

        let file = KeptFile(name: "a.fits", localPath: "/tmp/a.fits", size: 3, downloadedAt: Date(timeIntervalSince1970: 0), isMain: true)
        let saved = store.save(details().keeping(file))
        let reloaded = ObservationStore(fileName: fileName, spotlight: nil).observations.first { $0.id == saved.id }
        XCTAssertEqual(reloaded?.keptFiles.map(\.name), ["a.fits"])
        XCTAssertEqual(reloaded?.keptFiles.first?.isMain, false)
    }

    /// Deleting the observation deletes every file it keeps.
    func testDeletingTheObservationDeletesAllItsFiles() async throws {
        let research = ResearchModel(observationStore: store,
                                     downloadService: DownloadService(session: MockURLProtocol.mockSession(), tasks: TaskRegistry()))
        let (record, file) = try await research.files.download(.artifact(uri: "cadc:CFHT/2388466o.fits.fz"), for: details())
        research.deleteObservation(record)
        for _ in 0..<100 where !store.observations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.observations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.localPath))
    }
}

/// Plan 34 F: the person sees and chooses the download folder; a folder
/// that is gone sends downloads to Downloads, and says so.
@MainActor
final class DownloadFolderSettingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DownloadFolderSettingTests-\(UUID().uuidString)")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("chosen-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        DownloadsFolder.chosen.withLock { $0 = nil }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testDownloadsGoToTheChosenFolderUntilThePersonGoesBack() throws {
        let setting = DownloadFolderSetting(defaults: defaults)
        XCTAssertTrue(setting.isDownloads)
        XCTAssertEqual(DownloadsFolder.url, DownloadsFolder.system)

        setting.choose(folder)
        XCTAssertFalse(setting.isDownloads)
        XCTAssertEqual(DownloadsFolder.url.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        XCTAssertEqual(DownloadFolderSetting(defaults: defaults).folder.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath(),
                       "kept for the next launch")

        setting.useDownloads()
        XCTAssertTrue(setting.isDownloads)
        XCTAssertEqual(DownloadsFolder.url, DownloadsFolder.system)
    }

    func testAChosenFolderThatIsGoneSendsDownloadsToDownloadsAndSaysSo() throws {
        let setting = DownloadFolderSetting(defaults: defaults)
        setting.choose(folder)
        try FileManager.default.removeItem(at: folder)

        let later = DownloadFolderSetting(defaults: defaults)
        XCTAssertNotNil(later.unavailable)
        XCTAssertEqual(DownloadsFolder.url, DownloadsFolder.system)
        XCTAssertTrue(later.isDownloads)
    }
}
