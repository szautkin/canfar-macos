// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// The person's request (2026-10-09): a Research file goes to their CANFAR
/// storage and comes back, Research shows where each is, and a copy is
/// removed only while the other is there — a file always keeps one.
@MainActor
final class ResearchFileTransferTests: XCTestCase {
    /// The person's storage, in memory.
    actor FakeStorage: ResearchStorage {
        private(set) var files: [String: Data] = [:]
        private(set) var removed: [String] = []

        /// The next send fails, as CANFAR storage out of service would.
        var failNextSend = false
        func failNext() { failNextSend = true }

        func send(_ file: URL, toFolder folder: String) async throws -> String {
            if failNextSend { failNextSend = false; throw URLError(.cannotConnectToHost) }
            let path = "\(folder)/\(file.lastPathComponent)"
            let data = try Data(contentsOf: file)
            if let there = files[path] {
                guard there.count == data.count else { throw CocoaError(.fileWriteFileExists) }
                return path
            }
            files[path] = data
            return path
        }

        func fetch(_ path: String) async throws -> URL {
            guard let data = files[path] else { throw CocoaError(.fileNoSuchFile) }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fetch-\(UUID().uuidString)")
            try data.write(to: temp)
            return temp
        }

        func remove(_ path: String) async throws {
            guard files.removeValue(forKey: path) != nil else { throw CocoaError(.fileNoSuchFile) }
            removed.append(path)
        }

        func put(_ path: String, _ data: Data) { files[path] = data }

        /// Removed elsewhere — another device, or the Storage screen.
        func drop(_ path: String) { files[path] = nil }
        /// Storage out of reach for the next question about a file.
        var unreachable = false
        func setUnreachable(_ value: Bool) { unreachable = value }

        func size(_ path: String) async throws -> Int64? {
            if unreachable { throw URLError(.cannotFindHost) }
            return files[path].map { Int64($0.count) }
        }
    }

    private var fileName = ""
    private var folder: URL!
    private var store: ObservationStore!
    private var transfer: ResearchFileTransfer!
    private var storage: FakeStorage!

    private let fitsName = "2388466p.fits.fz"
    private let bytes = Data("SIMPLE  =                    T".utf8) + Data(count: 2048)
    private var inStorage: String { "\(ResearchFileTransfer.folder)/\(fitsName)" }

    override func setUp() async throws {
        try await super.setUp()
        fileName = "test-file-transfer-\(UUID().uuidString).json"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never the person's Downloads.
        let downloads = folder
        DownloadsFolder.chosen.withLock { $0 = downloads }
        store = ObservationStore(fileName: fileName, spotlight: nil, database: try AppDatabase.makeInMemory())
        let service = DownloadService(session: MockURLProtocol.mockSession(), tasks: TaskRegistry())
        transfer = ResearchFileTransfer(store: store, files: ResearchFiles(store: store, downloads: service),
                                        downloads: service, changes: ChangeLog())
        transfer.tasks = TaskRegistry()
        storage = FakeStorage()
        transfer.storage = storage
    }

    override func tearDown() {
        DownloadsFolder.chosen.withLock { $0 = nil }
        try? FileManager.default.removeItem(at: folder)
        let dir = Optional(AppSupport.directory)?
            .appendingPathComponent("Verbinal")
        if let dir { try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName)) }
        super.tearDown()
    }

    /// A record whose main file is on this Mac.
    private func onMac() throws -> DownloadedObservation {
        let file = folder.appendingPathComponent(fitsName)
        try bytes.write(to: file)
        var record = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?2388466/2388466p", collection: "CFHT",
                                           observationID: "2388466", targetName: "M31", instrument: "MegaPrime", filter: "r",
                                           ra: "", dec: "", startDate: "", calLevel: "2", localPath: file.path)
        record.fileSize = Int64(bytes.count)
        return store.save(record)
    }

    /// A record whose main file is only in the person's storage.
    private func onlyInStorage() async -> DownloadedObservation {
        await storage.put(inStorage, bytes)
        var record = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/CFHT?2388466/2388466p", collection: "CFHT",
                                           observationID: "2388466", targetName: "M31", instrument: "MegaPrime", filter: "r",
                                           ra: "", dec: "", startDate: "", calLevel: "2", localPath: "")
        record.storagePath = inStorage
        record.fileSize = Int64(bytes.count)
        return store.save(record)
    }

    func testSendingAFileKeepsItOnThisMacAndSaysWhereItIsInStorage() async throws {
        let record = try onMac()
        XCTAssertEqual(record.mainKeptFile?.places, FilePlaces(onMac: true, inStorage: false))

        let sent = try await transfer.send(fitsName, of: record.id)
        XCTAssertEqual(sent.storagePath, inStorage)
        XCTAssertEqual(sent.mainKeptFile?.places, FilePlaces(onMac: true, inStorage: true))
        XCTAssertTrue(sent.fileExists, "the copy on this Mac stays")
        let kept = await storage.files[inStorage]
        XCTAssertEqual(kept, bytes)
        XCTAssertEqual(store.observation(id: record.id)?.storagePath, inStorage, "kept with the record")
    }

    func testTheCopyOnThisMacGoesAndComesBackFromStorage() async throws {
        let record = try onMac()
        try await transfer.send(fitsName, of: record.id)

        let away = try await transfer.removeFromMac(fitsName, of: record.id)
        XCTAssertFalse(away.isDownloaded)
        XCTAssertEqual(away.storagePath, inStorage, "still known in storage")
        XCTAssertEqual(away.fileSize, Int64(bytes.count), "with its size")
        XCTAssertEqual(away.mainKeptFile?.places, FilePlaces(onMac: false, inStorage: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(fitsName).path))

        let back = try await transfer.fetch(fitsName, of: record.id)
        XCTAssertTrue(back.fileExists)
        XCTAssertEqual(back.mainKeptFile?.places, FilePlaces(onMac: true, inStorage: true))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(back.localURL)), bytes)
    }

    /// Live, plan 44 F-8: the copy on this Mac was removed while storage
    /// could not be reached, on the record's word that a copy was there.
    func testACopyGoneFromStorageSinceKeepsThisOne() async throws {
        let record = try onMac()
        try await transfer.send(fitsName, of: record.id)
        await storage.drop(inStorage)
        do {
            try await transfer.removeFromMac(fitsName, of: record.id)
            XCTFail("the copy in storage is gone: this is the last")
        } catch let failure as ResearchFileTransfer.Failure {
            XCTAssertEqual(failure, .onlyCopy(fitsName))
        }
        let kept = try XCTUnwrap(store.observation(id: record.id))
        XCTAssertTrue(kept.fileExists, "it stays")
        XCTAssertNil(kept.storagePath, "and the record no longer says storage has it")
    }

    func testStorageOutOfReachKeepsThisOne() async throws {
        let record = try onMac()
        try await transfer.send(fitsName, of: record.id)
        await storage.setUnreachable(true)
        do {
            try await transfer.removeFromMac(fitsName, of: record.id)
            XCTFail("storage could not say its copy is there")
        } catch let failure as ResearchFileTransfer.Failure {
            guard case .cannotCheck(let name, _) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(name, fitsName)
        }
        XCTAssertTrue(store.observation(id: record.id)?.fileExists == true, "it stays")
        XCTAssertEqual(store.observation(id: record.id)?.storagePath, inStorage, "storage's copy is not given up on")
    }

    func testTheLastCopyIsNeverRemoved() async throws {
        let onlyHere = try onMac()
        do {
            try await transfer.removeFromMac(fitsName, of: onlyHere.id)
            XCTFail("the only copy")
        } catch let failure as ResearchFileTransfer.Failure {
            XCTAssertEqual(failure, .onlyCopy(fitsName))
        }
        XCTAssertTrue(store.observation(id: onlyHere.id)?.fileExists == true)

        store.remove(onlyHere)
        let onlyThere = await onlyInStorage()
        do {
            try await transfer.removeFromStorage(fitsName, of: onlyThere.id)
            XCTFail("the only copy")
        } catch let failure as ResearchFileTransfer.Failure {
            XCTAssertEqual(failure, .onlyCopy(fitsName))
        }
        let stays = await storage.files[inStorage]
        XCTAssertNotNil(stays)
    }

    func testAMoveCopiesFirstAndRemovesTheOtherCopyAfter() async throws {
        let record = try onMac()
        let there = try await transfer.move(fitsName, of: record.id, to: .storage)
        XCTAssertEqual(there.mainKeptFile?.places, FilePlaces(onMac: false, inStorage: true))

        let here = try await transfer.move(fitsName, of: record.id, to: .mac)
        XCTAssertEqual(here.mainKeptFile?.places, FilePlaces(onMac: true, inStorage: false))
        XCTAssertTrue(here.fileExists)
        let left = await storage.files
        XCTAssertTrue(left.isEmpty)
        let removed = await storage.removed
        XCTAssertEqual(removed, [inStorage])
    }

    func testAFileOfTheSameNameInTheDownloadFolderIsKeptWhenOneComesBack() async throws {
        let record = await onlyInStorage()
        let other = Data("someone else's".utf8)
        try other.write(to: folder.appendingPathComponent(fitsName))

        let here = try await transfer.move(fitsName, of: record.id, to: .mac)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(fitsName)), other, "never written over")
        XCTAssertNotEqual(here.localURL?.lastPathComponent, fitsName)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(here.localURL)), bytes)
        XCTAssertEqual(here.mainKeptFile?.places, FilePlaces(onMac: true, inStorage: false))
    }

    func testAnObservationsOtherFileTravelsByItsName() async throws {
        let main = try onMac()
        let otherName = "2388466o.fits.fz"
        let otherFile = folder.appendingPathComponent(otherName)
        try bytes.write(to: otherFile)
        let record = store.save(main.keeping(KeptFile(name: otherName, localPath: otherFile.path, size: Int64(bytes.count),
                                                      downloadedAt: Date())))

        try await transfer.send(otherName, of: record.id)
        let away = try await transfer.removeFromMac(otherName, of: record.id)
        let file = try XCTUnwrap(away.anyFile(named: otherName))
        XCTAssertEqual(file.places, FilePlaces(onMac: false, inStorage: true))
        XCTAssertEqual(file.storagePath, "\(ResearchFileTransfer.folder)/\(otherName)")
        XCTAssertNil(away.keptFile(named: otherName), "not on this Mac")
        XCTAssertEqual(away.mainKeptFile?.places, FilePlaces(onMac: true, inStorage: false), "the main file is untouched")

        let back = try await transfer.fetch(otherName, of: record.id)
        XCTAssertEqual(back.anyFile(named: otherName)?.places, FilePlaces(onMac: true, inStorage: true))
        XCTAssertTrue(back.keptFile(named: otherName)?.local.exists == true)
    }

    func testSignedOutNothingMoves() async throws {
        let record = try onMac()
        transfer.storage = nil
        do {
            try await transfer.send(fitsName, of: record.id)
            XCTFail("signed out")
        } catch let failure as ResearchFileTransfer.Failure {
            XCTAssertEqual(failure, .signedOut)
        }
        XCTAssertNil(store.observation(id: record.id)?.storagePath)
    }

    func testForgettingTheFileOnThisMacKeepsWhereItIsInStorage() throws {
        var record = try onMac()
        record.storagePath = inStorage
        let forgotten = record.forgetting(fileNamed: fitsName)
        XCTAssertEqual(forgotten.storagePath, inStorage)
        XCTAssertEqual(forgotten.mainKeptFile?.places, FilePlaces(onMac: false, inStorage: true))
        XCTAssertNil(record.withoutFile().mainKeptFile, "without its file anywhere")
    }

    func testAnAssistantIsToldWhereEachFileIs() {
        XCTAssertEqual(FilePlaces(onMac: true, inStorage: true).word, "both")
        XCTAssertEqual(FilePlaces(onMac: true, inStorage: false).word, "mac")
        XCTAssertEqual(FilePlaces(onMac: false, inStorage: true).word, "storage")
        XCTAssertEqual(FilePlaces(onMac: false, inStorage: false).word, "none")
    }

    /// Live, 2026-10-17 (plan 44 D): removing the copy on this Mac of a file
    /// only on this Mac went to Pending as "it stays in your storage", and
    /// would have failed once the person applied it. What cannot be done is
    /// refused when it is asked, saying why; what can is proposed.
    func testWhatATransferCannotDoIsRefusedWhenAsked() async throws {
        let app = AppState()
        let tools = app.makeAgentTools()
        let send = try XCTUnwrap(tools.compactMap { $0 as? SendResearchFileToStorageTool }.first)
        let get = try XCTUnwrap(tools.compactMap { $0 as? GetResearchFileFromStorageTool }.first)
        let fromMac = try XCTUnwrap(tools.compactMap { $0 as? RemoveResearchFileFromMacTool }.first)
        let fromStorage = try XCTUnwrap(tools.compactMap { $0 as? RemoveResearchFileFromStorageTool }.first)
        let store = app.researchModel.observationStore
        func kept(_ name: String, onMac: Bool, inStorage: Bool) -> DownloadedObservation {
            var record = DownloadedObservation(publisherID: "ivo://cadc.nrc.ca/TEST?qa44-\(UUID().uuidString)/\(name)",
                                               collection: "TEST", observationID: name, targetName: "M31", instrument: "",
                                               filter: "", ra: "", dec: "", startDate: "", calLevel: "2",
                                               localPath: onMac ? folder.appendingPathComponent("\(name).fits").path : "")
            record.storagePath = inStorage ? "\(ResearchFileTransfer.folder)/\(name).fits" : nil
            return store.save(record)
        }
        let here = kept("here", onMac: true, inStorage: false)
        let there = kept("there", onMac: false, inStorage: true)
        let both = kept("both", onMac: true, inStorage: true)
        defer { [here, there, both].forEach(store.remove) }
        let context = AIToolContext(origin: .external(clientID: "test"), proposals: InMemoryProposalStore(),
                                    budget: ProposalBudget(limit: 9))
        func refusal(_ plan: () async throws -> ProposalPlan) async -> String? {
            do { _ = try await plan(); return nil } catch { return "\(error)" }
        }
        let losesHere = await refusal { try await fromMac.plan(.init(id: here.id.uuidString), context: context) }
        XCTAssertTrue(losesHere?.contains("would lose it") == true, "the copy on this Mac is its last: \(losesHere ?? "proposed")")
        let losesThere = await refusal { try await fromStorage.plan(.init(id: there.id.uuidString), context: context) }
        XCTAssertTrue(losesThere?.contains("would lose it") == true, "the copy in storage is its last: \(losesThere ?? "proposed")")
        let notHere = await refusal { try await send.plan(.init(id: there.id.uuidString), context: context) }
        XCTAssertTrue(notHere?.contains("is not on this Mac") == true, "\(notHere ?? "proposed")")
        let notThere = await refusal { try await get.plan(.init(id: here.id.uuidString), context: context) }
        XCTAssertTrue(notThere?.contains("is not in your storage") == true, "\(notThere ?? "proposed")")
        let unknown = await refusal { try await fromMac.plan(.init(id: UUID().uuidString), context: context) }
        XCTAssertTrue(unknown?.contains("in Research") == true, "\(unknown ?? "proposed")")

        let fine = await refusal { try await fromMac.plan(.init(id: both.id.uuidString), context: context) }
        XCTAssertNil(fine, "a file in both places: its copy here may go")
    }

    /// Plan 44 E4: a transfer that failed — storage out of service — is on
    /// the bar with Retry, the person's; it goes when tried again.
    func testAFailedTransferIsTriedAgainFromTheBar() async throws {
        let record = try onMac()
        let registry = TaskRegistry()
        transfer.tasks = registry
        await storage.failNext()
        do { try await transfer.send(fitsName, of: record.id); XCTFail("storage out of service") } catch {}
        let failed = try XCTUnwrap(registry.tasks.last)
        XCTAssertEqual(failed.progress, .failed)
        XCTAssertTrue(failed.canRetry)
        XCTAssertNotNil(registry.retry(failed.id, by: .assistant), "an assistant calls the tool again instead")
        XCTAssertNil(registry.retry(failed.id, by: .person))
        try await Task.sleep(for: .milliseconds(300))
        let sent = await storage.files[inStorage]
        XCTAssertEqual(sent, bytes, "it went when tried again")
        XCTAssertEqual(store.record(identifiedBy: record.id.uuidString)?.mainKeptFile?.places.word, "both")
    }

    func testEachToolIsTheKindOfChangeItMakes() {
        XCTAssertEqual(ChangeCatalog.kind(ofTool: "send_research_file_to_storage"), .addToStorage)
        XCTAssertEqual(ChangeCatalog.kind(ofTool: "get_research_file_from_storage"), .filesOnMac)
        XCTAssertEqual(ChangeCatalog.kind(ofTool: "remove_research_file_from_mac"), .removeFilesOnMac)
        XCTAssertEqual(ChangeCatalog.kind(ofTool: "remove_research_file_from_storage"), .removeFromStorage)
        XCTAssertEqual(RemoveResearchFileFromMacTool.verbClass, .destructive)
        XCTAssertEqual(RemoveResearchFileFromStorageTool.verbClass, .destructive)
    }
}
