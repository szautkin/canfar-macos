// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// A Research record describes the plane its file belongs to (plan 15 F6:
/// QA H5, M2, M11). The fixture is the archive's own record of the M31
/// MegaPipe tile the report names, cut to its g- and u-band planes.
final class ResearchRecordDetailsTests: XCTestCase {

    private let gBand = "ivo://cadc.nrc.ca/CFHTMEGAPIPE?MegaPipe.016.263/MegaPipe.016.263.G.MP9401"
    private let uBand = "ivo://cadc.nrc.ca/CFHTMEGAPIPE?MegaPipe.016.263/MegaPipe.016.263.U.MP9301"

    private func megaPipe() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "megapipe-016-263", withExtension: "xml"))
        return try Data(contentsOf: url)
    }

    private func described(_ publisherID: String, filter: String = "", target: String = "",
                           preview: String? = nil) -> DownloadedObservation {
        DownloadedObservation(publisherID: publisherID, collection: "", observationID: "", targetName: target,
                              instrument: "", filter: filter, ra: "", dec: "", startDate: "", calLevel: "",
                              localPath: "", previewURL: preview)
    }

    private let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(),
                                    budget: ProposalBudget(limit: 9))

    // MARK: - H5: the record says what the file is

    /// The reported record: the g band's filter and preview, the u band's
    /// file. The archive's word for the u-band plane wins.
    func testTheRecordDescribesThePlaneItsFileBelongsTo() throws {
        let observation = try CAOM2Parser.parse(data: try megaPipe())
        let told = described(uBand, filter: "G.MP9401", target: "M31",
                             preview: "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca/data/pub/CFHTSG/MegaPipe.016.263.G.MP9401.fits.gif")

        let record = ResearchRecordDetails.completing(told, from: observation)

        XCTAssertEqual(record.filter, "u.MP9301")
        XCTAssertTrue(record.previewURL?.hasSuffix("MegaPipe.016.263.U.MP9301.fits.gif") == true, record.previewURL ?? "nil")
        XCTAssertEqual(record.collection, "CFHTMEGAPIPE")
        XCTAssertEqual(record.observationID, "MegaPipe.016.263")
        XCTAssertEqual(record.instrument, "MegaPrime")
        XCTAssertEqual(record.targetName, "M 31 LL", "the archive's name for the target")
        XCTAssertEqual(record.calLevel, "3")
        XCTAssertEqual(try XCTUnwrap(Double(record.ra)), 10.68, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(Double(record.dec)), 41.27, accuracy: 0.5)
    }

    func testAPlaneIsFoundByItsProductID() throws {
        let observation = try CAOM2Parser.parse(data: try megaPipe())
        let plane = ResearchRecordDetails.plane(of: try XCTUnwrap(PublisherID(gBand)), in: observation)
        XCTAssertEqual(plane?.productID, "MegaPipe.016.263.G.MP9401")
        XCTAssertEqual(plane?.position?.polygon.count, 4, "CAOM 2.4's bounds/points/point outline")
        XCTAssertNil(ResearchRecordDetails.plane(of: try XCTUnwrap(PublisherID("ivo://cadc.nrc.ca/CFHTMEGAPIPE?MegaPipe.016.263")),
                                                 in: observation), "no product named, two planes: none is the one")
    }

    // MARK: - M2: blanks the publisher ID can fill; a malformed one is refused

    func testWithoutTheArchiveThePublisherIDFillsTheBlanks() {
        let cfht = ResearchRecordDetails.completing(described("ivo://cadc.nrc.ca/CFHT?1573200", filter: "i.MP9701"), from: nil)
        XCTAssertEqual(cfht.collection, "CFHT")
        XCTAssertEqual(cfht.observationID, "1573200")
        XCTAssertEqual(cfht.filter, "i.MP9701", "a description stands where the archive said nothing")

        let iris = ResearchRecordDetails.completing(described("ivo://cadc.nrc.ca/IRIS?f081h000/IRAS-100um"), from: nil)
        XCTAssertEqual([iris.collection, iris.observationID], ["IRIS", "f081h000"])

        let jcmt = PublisherID("caom:JCMT/scuba2_00066_20130813T161227/reduced-850um")
        XCTAssertEqual(jcmt?.collection, "JCMT")
        XCTAssertEqual(jcmt?.observationID, "scuba2_00066_20130813T161227")
        XCTAssertEqual(jcmt?.productID, "reduced-850um")
    }

    func testAMalformedPublisherIDIsRefusedWithTheOneItMeans() async throws {
        let slash = "ivo://cadc.nrc.ca/CFHT/1525350"
        XCTAssertNil(PublisherID(slash))
        let plans: [() async throws -> Void] = [
            { _ = try await DownloadObservationTool().plan(.init(publisher_id: slash), context: self.ctx) },
            { _ = try await DownloadObservationsBulkTool().plan(.init(items: [.init(publisher_id: self.uBand), .init(publisher_id: slash)]),
                                                                context: self.ctx) },
            { _ = try await SaveObservationToResearchTool().plan(.init(publisherId: slash), context: self.ctx) },
        ]
        for plan in plans {
            do {
                try await plan()
                XCTFail("\(slash) is not a publisher ID")
            } catch ToolFailureReason.invalidArgument(let message) {
                XCTAssertTrue(message.contains("did you mean ivo://cadc.nrc.ca/CFHT?1525350"), message)
            }
        }
    }

    // MARK: - M11: one of the plane's files, by name; only the plane's

    private func service(serving files: @escaping @Sendable (URL) -> Data?) throws -> DownloadService {
        let caom = try megaPipe()
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let ok = { (body: Data) in (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, body) }
            if url.path.contains("datalink") { return ok(Data("<VOTABLE/>".utf8)) }   // no #this, as for these planes
            if url.path.contains("meta") { return ok(caom) }
            guard let body = files(url) else {
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return ok(body)
        }
        let session = MockURLProtocol.mockSession()
        return DownloadService(session: session, caom2: CAOM2Service(session: session), tasks: TaskRegistry())
    }

    func testADownloadTakesTheFileItIsAskedFor() async throws {
        defer { MockURLProtocol.requestHandler = nil }
        let downloads = try service { url in Data(repeating: 0x41, count: url.lastPathComponent.hasSuffix(".fz") ? 2880 : 5760) }
        let weight = "MegaPipe.016.263.U.MP9301.weight.fits.fz"
        let got = try await downloads.downloadToTemp(publisherID: uBand, file: weight)
        defer { try? FileManager.default.removeItem(at: got.tempURL) }
        XCTAssertEqual(got.suggestedFilename, weight)
        XCTAssertEqual(try Data(contentsOf: got.tempURL).count, 2880)

        do {
            _ = try await downloads.downloadToTemp(publisherID: uBand, file: "MegaPipe.016.263.G.MP9401.fits")
            XCTFail("a sibling plane's file is not this plane's")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("get_data_links"), error.localizedDescription)
        }

        let plan = try await DownloadObservationTool().plan(.init(publisher_id: uBand, file: " \(weight) "), context: ctx)
        XCTAssertEqual(try JSONDecoder().decode(DownloadObservationTool.Payload.self, from: plan.payload).file, weight)
    }

    /// Without DataLink, the science file comes from the plane the ID
    /// names — the g band's comes first in the archive's record.
    func testTheBestPickIsFromThePlaneTheIDNames() async throws {
        defer { MockURLProtocol.requestHandler = nil }
        let downloads = try service { _ in Data(repeating: 0x41, count: 2880) }
        let got = try await downloads.downloadToTemp(publisherID: uBand)
        defer { try? FileManager.default.removeItem(at: got.tempURL) }
        XCTAssertEqual(got.suggestedFilename, "MegaPipe.016.263.U.MP9301.fits")
    }

    // MARK: - Records kept before (plan 17 G3, QA regression H5, M2)

    /// A store of its own, and the file to remove after.
    @MainActor
    private func temporaryStore() -> (ObservationStore, URL) {
        let name = "test_observations_\(UUID().uuidString).json"
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbinal").appendingPathComponent(name)
        return (ObservationStore(fileName: name, spotlight: nil), file)
    }

    private func archiveRecord(_ name: String) throws -> CAOM2Observation {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "xml"))
        return try CAOM2Parser.parse(data: try Data(contentsOf: url))
    }

    /// Plan 19 R2 (QA M2): CFHT?1573200 names no product, and its
    /// observation has two (`i`, level 2; `o`, level 1). The plane is the one
    /// that holds the downloaded file; with none downloaded, the observation's
    /// target and instrument still come (the archive's own answer, fetched
    /// live 2026-09-29).
    func testARecordWithoutAProductTakesThePlaneOfItsFile() throws {
        let caom = try archiveRecord("cfht-1573200")
        var raw = described("ivo://cadc.nrc.ca/CFHT?1573200")
        raw.localPath = "/Users/u/Downloads/1573200o.fits"
        let withFile = ResearchRecordDetails.completing(raw, from: caom)
        XCTAssertEqual(withFile.calLevel, "1", "the o plane holds 1573200o.fits.fz")
        XCTAssertEqual(withFile.targetName, "Betelgeuse")
        XCTAssertEqual(withFile.instrument, "ESPaDOnS")

        let withoutFile = ResearchRecordDetails.completing(described("ivo://cadc.nrc.ca/CFHT?1573200"), from: caom)
        XCTAssertEqual(withoutFile.targetName, "Betelgeuse")
        XCTAssertEqual(withoutFile.instrument, "ESPaDOnS")
        XCTAssertEqual(withoutFile.calLevel, "", "no plane to choose without a file")
        XCTAssertTrue(ResearchRecordDetails.sameFile("cadc:CFHT/1573200o.fits.fz", "1573200O.FITS"))
        XCTAssertFalse(ResearchRecordDetails.sameFile("cadc:CFHT/1573200i.fits", "1573200o.fits"))
    }

    /// QA M2: the DECam-era NOAO records' instrument stayed blank. The
    /// archive has it; the check that never got an answer is what missed it.
    func testANOAORecordGetsItsInstrument() throws {
        let caom = try archiveRecord("noao-tu636792")
        let record = ResearchRecordDetails.completing(described("ivo://cadc.nrc.ca/NOAO?tu636792/tu636792"), from: caom)
        XCTAssertEqual(record.instrument, "mosaic_2")
        XCTAssertEqual(record.observationID, "tu636792")
    }

    /// Plan 21 N1: a QA pass typed `475879F9E-122A-…` (a digit too many)
    /// and read the record as unopenable; `open_cube` took no publisher id.
    /// A miss names the id it most likely means; any of the record's own
    /// identifiers finds it.
    @MainActor
    func testATypedIdNamesTheRecordItMostLikelyMeans() throws {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        var cube = described("ivo://cadc.nrc.ca/mirror/JWST?jw09230-o004_t001_nirspec_g395h-f290lp/jw09230-o004_t001_nirspec_g395h-f290lp-PRODUCT")
        cube.id = try XCTUnwrap(UUID(uuidString: "475879F9-122A-4CD3-9E37-A336ABFEBD0A"))
        cube.observationID = "jw09230-o004_t001_nirspec_g395h-f290lp"
        store.save(cube)
        store.save(described(uBand))

        XCTAssertEqual(store.likelyID(for: "475879F9E-122A-4CD3-9E37-A336ABFEBD0A"), cube.id, "a digit added")
        XCTAssertEqual(store.likelyID(for: "475879F-122A-4CD3-9E37-A336ABFEBD0A"), cube.id, "a digit dropped")
        XCTAssertNil(store.likelyID(for: "00000000-122A-4CD3-9E37-A336ABFEBD0A"), "too far to name")
        XCTAssertThrowsError(try store.recordForTool("475879F9E-122A-4CD3-9E37-A336ABFEBD0A")) { error in
            XCTAssertTrue("\(error)".contains("did you mean 475879F9-122A-4CD3-9E37-A336ABFEBD0A"), "\(error)")
        }
        XCTAssertEqual(try store.recordForTool(cube.publisherID).id, cube.id, "its publisher id finds it")
        XCTAssertEqual(try store.recordForTool("475879F9").id, cube.id, "an id prefix finds it")
    }

    /// The archive, as the check sees it: what this Mac keeps, and what the
    /// network answers — slowly, and counted.
    private final class FakeArchive: ArchiveObservations, @unchecked Sendable {
        private let lock = NSLock()
        private var keptAnswers: [String: CAOM2Observation] = [:]
        private let answers: [String: CAOM2Observation]
        private(set) var asked: [String] = []
        private(set) var mostAtOnce = 0
        private var atOnce = 0
        init(answers: [String: CAOM2Observation] = [:], kept: [String: CAOM2Observation] = [:]) {
            (self.answers, self.keptAnswers) = (answers, kept)
        }
        func kept(publisherID: String) async -> CAOM2Observation? { lock.withLock { keptAnswers[publisherID] } }
        func observation(publisherID: String, within seconds: TimeInterval) async -> CAOM2Observation? {
            lock.withLock { asked.append(publisherID); atOnce += 1; mostAtOnce = max(mostAtOnce, atOnce) }
            try? await Task.sleep(for: .milliseconds(20))
            return lock.withLock {
                atOnce -= 1
                if let answer = answers[publisherID] { keptAnswers[publisherID] = answer }
                return answers[publisherID]
            }
        }
    }

    /// Plan 17 G3, plan 19 R1: a record kept before is brought up to the
    /// archive; asked once, as the answer is then kept on this Mac.
    @MainActor
    func testRecordsKeptBeforeAreBroughtUpToTheArchiveAndAskedOnce() async throws {
        let caom = try CAOM2Parser.parse(data: try megaPipe())
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        var legacy = described(uBand, filter: "G.MP9401", target: "M31")
        legacy.localPath = "/tmp/MegaPipe.016.263.U.MP9301.fits"
        store.save(legacy)
        let archive = FakeArchive(answers: [uBand: caom])
        let repair = ResearchRecordRepair(store: store, tasks: TaskRegistry(), archive: archive)

        let changed = await repair.run()

        XCTAssertEqual(changed, 1)
        let record = try XCTUnwrap(store.observations.first)
        XCTAssertEqual(record.filter, "u.MP9301")
        XCTAssertEqual(record.observationID, "MegaPipe.016.263", "M2: no longer blank")
        XCTAssertEqual(record.localPath, legacy.localPath, "the file stays the record's")
        XCTAssertEqual(record.id, legacy.id)
        let again = await repair.run()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(archive.asked, [uBand], "the second check reads what this Mac keeps")
        XCTAssertNil(repair.progress)
    }

    /// Plan 19 R1: a record the archive did not answer is asked again at
    /// the next check — the first check marked itself done regardless.
    @MainActor
    func testARecordTheArchiveDidNotAnswerIsAskedAgain() async throws {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        store.save(described("ivo://cadc.nrc.ca/CFHT?1573200"))
        let archive = FakeArchive()
        let repair = ResearchRecordRepair(store: store, tasks: TaskRegistry(), archive: archive)
        await repair.run()
        XCTAssertEqual(store.observations.first?.collection, "CFHT", "the publisher id fills what it can meanwhile")
        await repair.run()
        XCTAssertEqual(archive.asked.count, 2)
    }

    /// Plan 19 R1 (QA N15: 35 records in about 20 minutes, one at a time):
    /// two requests at once, the progress on the bar.
    @MainActor
    func testTheArchiveIsAskedTwoAtATimeWithProgress() async throws {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        for n in 1...5 { store.save(described("ivo://cadc.nrc.ca/CFHT?15732\(n)")) }
        let registry = TaskRegistry()
        let archive = FakeArchive()
        let repair = ResearchRecordRepair(store: store, tasks: registry, archive: archive)
        await repair.run()
        XCTAssertEqual(archive.asked.count, 5)
        XCTAssertEqual(archive.mostAtOnce, ResearchRecordRepair.concurrentRequests)
        XCTAssertEqual(registry.tasks.map(\.label), ["Get archive details for Research records"])
        XCTAssertEqual(registry.tasks.first?.startedBy, .app)
        XCTAssertEqual(registry.tasks.first?.progress, .failed, "no answer is not a success (plan 21 D3)")
    }

    /// Plan 21 D3: with CADC down, 36 records waited out 18 minutes and the
    /// check said it had succeeded, "answered for 0 of 36". It stops once the
    /// archive has answered none of its first requests, and fails, saying so;
    /// an archive that answers for some is a success that says how many.
    @MainActor
    func testACheckStopsAndFailsWhenTheArchiveIsDown() async throws {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        for n in 10...45 { store.save(described("ivo://cadc.nrc.ca/CFHT?15732\(n)")) }
        let registry = TaskRegistry()
        let down = FakeArchive()
        await ResearchRecordRepair(store: store, tasks: registry, archive: down).run()
        XCTAssertLessThanOrEqual(down.asked.count, ResearchRecordRepair.givesUpAfter + ResearchRecordRepair.concurrentRequests,
                                 "not all 36")
        XCTAssertEqual(registry.tasks.first?.progress, .failed)
        XCTAssertEqual(registry.tasks.first?.message, ResearchRecordRepair.notAnswering)

        let caom = try CAOM2Parser.parse(data: try megaPipe())
        let (some, someFile) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: someFile) }
        some.save(described(uBand))
        some.save(described("ivo://cadc.nrc.ca/CFHT?1573200"))
        let partial = TaskRegistry()
        await ResearchRecordRepair(store: some, tasks: partial, archive: FakeArchive(answers: [uBand: caom])).run()
        XCTAssertEqual(partial.tasks.first?.progress, .succeeded)
        XCTAssertEqual(partial.tasks.first?.message, "The archive answered for 1 of 2")
    }

    /// Plan 19 R3: `1525350`, blank in the person's Research, was kept under
    /// the slash form and never looked up; its ID is corrected, its note
    /// goes with it, and the archive is asked under the ID it means.
    @MainActor
    func testARecordKeptUnderTheSlashFormIsCorrectedAndFilledIn() async throws {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let slash = "ivo://cadc.nrc.ca/CFHT/1525350", canonical = "ivo://cadc.nrc.ca/CFHT?1525350"
        let legacy = store.save(described(slash))
        let notes = ObservationNoteStore(database: try AppDatabase.makeInMemory(), legacyNotesSource: nil)
        notes.save(ObservationNote(publisherID: slash, text: "check the seeing", rating: 3, tags: ["qa"]))
        let archive = FakeArchive()
        let repair = ResearchRecordRepair(store: store, notes: notes, tasks: TaskRegistry(), archive: archive)
        await repair.run()

        XCTAssertEqual(archive.asked, [canonical], "looked up under the ID it means")
        let record = try XCTUnwrap(store.observations.first)
        XCTAssertEqual(record.publisherID, canonical)
        XCTAssertEqual(record.id, legacy.id, "the same record")
        XCTAssertEqual(record.observationID, "1525350")
        XCTAssertEqual(notes.note(for: canonical)?.text, "check the seeing")
        XCTAssertNil(notes.note(for: slash))
        XCTAssertEqual(PublisherID.malformed(slash).hasSuffix("did you mean \(canonical)?"), true)
        XCTAssertNil(PublisherID.likely("not an id"))
    }

    /// Plan 19 R1 (the person's blank records): a record added from Search
    /// gets its details from the archive when it is added, in the background.
    @MainActor
    func testARecordAddedGetsItsDetailsFromTheArchive() async throws {
        let caom = try CAOM2Parser.parse(data: try megaPipe())
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let model = ResearchModel(observationStore: store,
                                  noteStore: ObservationNoteStore(database: try AppDatabase.makeInMemory(), legacyNotesSource: nil))
        let registry = TaskRegistry()
        model.tasks = registry
        model.archive = FakeArchive(answers: [uBand: caom])
        let added = store.save(described(uBand))
        model.completeFromArchive(added)
        for _ in 0..<100 where store.observations.first?.filter != "u.MP9301" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.observations.first?.filter, "u.MP9301")
        XCTAssertEqual(store.observations.first?.targetName, "M 31 LL")
        XCTAssertEqual(registry.tasks.first?.label, "Archive details of \(uBand)")
    }

    /// The archive's answer, kept in the app's database, is read by the next
    /// client without the network (plan 19 R1).
    func testTheArchivesAnswerIsKeptInTheDatabase() async throws {
        let body = try megaPipe()
        final class Count: @unchecked Sendable { var requests = 0 }
        let count = Count()
        MockURLProtocol.requestHandler = { request in
            count.requests += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        defer { MockURLProtocol.requestHandler = nil }
        let kept = DatabaseArchiveObservationStore(database: try AppDatabase.makeInMemory())
        let first = CAOM2Service(session: MockURLProtocol.mockSession(), store: kept)
        let missing = await first.kept(publisherID: uBand)
        XCTAssertNil(missing)
        let fetched = await first.observation(publisherID: uBand, within: 10)
        XCTAssertNotNil(fetched)

        let second = CAOM2Service(session: MockURLProtocol.mockSession(), store: kept)
        let fromDisk = await second.kept(publisherID: uBand)
        XCTAssertEqual(fromDisk?.observationID, "MegaPipe.016.263")
        _ = try await second.fetch(publisherID: uBand)
        XCTAssertEqual(count.requests, 1, "asked of the archive once")
    }
}
