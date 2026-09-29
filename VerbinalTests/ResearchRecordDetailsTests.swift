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

    @MainActor
    func testRecordsKeptBeforeAreBroughtUpToTheArchiveOnce() async throws {
        let caom = try CAOM2Parser.parse(data: try megaPipe())
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        var legacy = described(uBand, filter: "G.MP9401", target: "M31")
        legacy.localPath = "/tmp/MegaPipe.016.263.U.MP9301.fits"
        store.save(legacy)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "repair-\(UUID().uuidString)"))
        final class Asked: @unchecked Sendable { var count = 0 }
        let asked = Asked()
        let repair = ResearchRecordRepair(store: store, tasks: TaskRegistry(), defaults: defaults) { _ in
            asked.count += 1
            return caom
        }

        let corrected = await repair.runOnce()

        XCTAssertEqual(corrected, 1)
        let record = try XCTUnwrap(store.observations.first)
        XCTAssertEqual(record.filter, "u.MP9301")
        XCTAssertEqual(record.observationID, "MegaPipe.016.263", "M2: no longer blank")
        XCTAssertEqual(record.localPath, legacy.localPath, "the file stays the record's")
        XCTAssertEqual(record.id, legacy.id)
        let again = await repair.runOnce()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(asked.count, 1, "once")
    }

    /// Plan 19 R3: `1525350`, blank in the person's Research, was kept under
    /// the slash form and never looked up; its ID is corrected, its note
    /// goes with it, and the archive fills it in.
    @MainActor
    func testARecordKeptUnderTheSlashFormIsCorrectedAndFilledIn() async throws {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        let slash = "ivo://cadc.nrc.ca/CFHT/1525350", canonical = "ivo://cadc.nrc.ca/CFHT?1525350"
        let legacy = store.save(described(slash))
        let notes = ObservationNoteStore(database: try AppDatabase.makeInMemory(), legacyNotesSource: nil)
        notes.save(ObservationNote(publisherID: slash, text: "check the seeing", rating: 3, tags: ["qa"],
                                   createdAt: Date(), modifiedAt: Date()))
        final class Asked: @unchecked Sendable { var ids: [String] = [] }
        let asked = Asked()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "repair-\(UUID().uuidString)"))
        let repair = ResearchRecordRepair(store: store, notes: notes, tasks: TaskRegistry(), defaults: defaults) { id in
            asked.ids.append(id)
            return nil
        }
        await repair.runOnce()

        XCTAssertEqual(asked.ids, [canonical], "looked up under the ID it means")
        let record = try XCTUnwrap(store.observations.first)
        XCTAssertEqual(record.publisherID, canonical)
        XCTAssertEqual(record.id, legacy.id, "the same record")
        XCTAssertEqual(record.observationID, "1525350")
        XCTAssertEqual(notes.note(for: canonical)?.text, "check the seeing")
        XCTAssertNil(notes.note(for: slash))
        XCTAssertEqual(PublisherID.malformed(slash).hasSuffix("did you mean \(canonical)?"), true)
        XCTAssertNil(PublisherID.likely("not an id"))
    }

    /// Offline, nothing is marked done: the next sign-in checks again.
    @MainActor
    func testACheckTheArchiveNeverAnsweredIsMadeAgain() async throws {
        let (store, file) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: file) }
        store.save(described("ivo://cadc.nrc.ca/CFHT?1573200"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "repair-\(UUID().uuidString)"))
        let repair = ResearchRecordRepair(store: store, tasks: TaskRegistry(), defaults: defaults) { _ in nil }
        await repair.runOnce()
        XCTAssertEqual(store.observations.first?.collection, "CFHT", "the publisher id fills what it can meanwhile")
        XCTAssertFalse(defaults.bool(forKey: ResearchRecordRepair.doneKey))
    }
}
