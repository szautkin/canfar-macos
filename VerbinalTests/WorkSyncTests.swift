// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import MCPCore
import VerbinalKit
@testable import Verbinal

/// Plan 36 tier 3: the person's work kept in VOSpace by one rule, each
/// collection by their own choice, and nothing for an account without
/// CANFAR storage.
@MainActor
final class WorkSyncTests: XCTestCase {
    typealias FakeVOSpace = StorageSyncTests.FakeVOSpace

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("work-sync-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func sync(_ remote: FakeVOSpace, _ kinds: [any StorageKind], device: String) -> StorageSync {
        StorageSync(remote: remote, catalog: StorageKindCatalog(kinds: kinds),
                    stateFile: directory.appendingPathComponent("state-\(device).json"))
    }

    private func manifest(_ kinds: [String: String]) -> Data {
        let entries = kinds.map { #""\#($0.key)": { "folder": "\#($0.value)", "format": 1, "since": "2026-10-09T12:00:00Z" }"# }
        return Data(#"{ "format": "verbinal.vospace-manifest", "version": 1, "kinds": { \#(entries.joined(separator: ", ")) } }"#.utf8)
    }

    private func queries() -> SavedQueryStore {
        SavedQueryStore(fileName: "test-sync-queries-\(UUID().uuidString).json")
    }

    // MARK: - The rule, for any list

    func testASavedQueryTravelsWithItsDatesAndSoDoesItsRemoval() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["savedQueries": ".verbinal/queries"]))
        let a = queries(), b = queries()
        a.save(SavedQuery(name: "M31 deep", adql: "SELECT TOP 10 * FROM caom2.Observation", tags: ["m31"]))
        let syncA = sync(remote, [a.syncCollection().kind], device: "a")
        let syncB = sync(remote, [b.syncCollection().kind], device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)
        let arrived = try XCTUnwrap(b.queries.first)
        XCTAssertEqual(arrived.name, "M31 deep")
        XCTAssertEqual(arrived.tags, ["m31"])
        XCTAssertEqual(arrived.savedAt.timeIntervalSince1970, a.queries[0].savedAt.timeIntervalSince1970, accuracy: 1,
                       "kept with its date, not the time it arrived")

        await syncB.sync(.asked)
        let quiet = await syncB.status().kinds.first?.sent
        XCTAssertEqual(quiet, 0, "what came is not sent back")

        a.remove(a.queries[0])
        await syncA.sync(.changed)
        await syncB.sync(.asked)
        XCTAssertTrue(b.queries.isEmpty, "a removal travels as a mark")
    }

    func testALaterBuildsFieldsInsideARecordSurviveAChangeHere() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["savedQueries": ".verbinal/queries"]))
        let id = UUID()
        let later: [String: Any] = [
            "format": 1, "key": id.uuidString, "changedAt": "2026-10-01T10:00:00Z", "writtenBy": "Verbinal for Linux",
            "record": ["id": id.uuidString, "name": "old name", "adql": "SELECT 1", "savedAt": "2026-10-01T10:00:00Z",
                       "description": "", "tags": [String](), "pinned": true],
        ]
        let path = ".verbinal/queries/" + SyncRecord<SavedQuery>.fileName(for: id.uuidString)
        await remote.put(path, try JSONSerialization.data(withJSONObject: later))
        let here = queries()
        let storage = sync(remote, [here.syncCollection().kind], device: "mac")
        await storage.sync(.signedIn)
        here.rename(try XCTUnwrap(here.queries.first), to: "new name")
        await storage.sync(.changed)

        let data = try await remote.read(path)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let record = try XCTUnwrap(sent["record"] as? [String: Any])
        XCTAssertEqual(record["name"] as? String, "new name", "this build's change went")
        XCTAssertEqual(record["pinned"] as? Bool, true, "a later build's field inside the record stayed")
        XCTAssertEqual(sent["writtenBy"] as? String, "Verbinal for Linux", "and one beside it")
    }

    func testOnlyTheCollectionsThePersonChoseAreSynced() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["savedQueries": ".verbinal/queries"]))
        let saved = queries()
        saved.save(SavedQuery(name: "kept", adql: "SELECT 1"))
        let recent = RecentSearchStore(fileName: "test-sync-recent-\(UUID().uuidString).json")
        recent.save(RecentSearch(name: "not chosen", formSnapshot: SearchFormSnapshot()))
        let storage = sync(remote, [saved.syncCollection().kind, recent.syncCollection().kind], device: "mac")
        await storage.sync(.signedIn)
        let files = await remote.files.keys
        XCTAssertTrue(files.contains { $0.hasPrefix(".verbinal/queries/") })
        XCTAssertFalse(files.contains { $0.hasPrefix(".verbinal/recent-searches/") }, "not chosen: not sent")
        let declared = await storage.status().kinds.filter(\.declared).map(\.id)
        XCTAssertEqual(declared, ["savedQueries"], "nothing is declared for the person")
    }

    /// The person's word (2026-10-09): only CANFAR's accounts have VOSpace.
    func testAnAccountWithoutCANFARStorageSyncsNothing() async throws {
        let remote = FakeVOSpace()
        await remote.setHome(false)
        let saved = queries()
        saved.save(SavedQuery(name: "stays here", adql: "SELECT 1"))
        let storage = sync(remote, [saved.syncCollection().kind, CountedKind.exports], device: "mac")
        await storage.sync(.signedIn)
        let lists = await remote.lists, files = await remote.files
        XCTAssertEqual(lists, [], "not even .verbinal is asked for")
        XCTAssertTrue(files.isEmpty)
        let status = await storage.status()
        XCTAssertEqual(status.hasStorage, false)
        XCTAssertNil(status.lastFailure, "not a failure")
        do {
            try await storage.setDeclared(["savedQueries"], true)
            XCTFail("nothing can be kept")
        } catch is StorageSync.NoStorage {}
        await storage.sync(.cameBack)
        let after = await remote.lists
        XCTAssertEqual(after, [], "an automatic sync does not look again")
    }

    // MARK: - Every collection, both ways (plan 44 A1, A4, A5)

    /// The two collections no test took from one device to another.
    func testAnAddedImageGoesBothWaysAndSoDoesItsRemoval() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["userImages": ".verbinal/images"]))
        let a = UserImageStore(persistence: nil), b = UserImageStore(persistence: nil)
        let id = "images.canfar.net/cirada/askapsoft-1.12.0-openmpi4:Oct24"
        a.add(RegistryImage(id: id, types: ["headless"]))
        let syncA = sync(remote, [a.syncCollection().kind], device: "a")
        let syncB = sync(remote, [b.syncCollection().kind], device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)
        XCTAssertEqual(b.images.map(\.id), [id], "with its tag as it is")

        XCTAssertTrue(b.remove(id))
        await syncB.sync(.changed)
        await syncA.sync(.asked)
        XCTAssertTrue(a.images.isEmpty, "removed there, removed here")
    }

    func testARemoteComputeRunGoesBothWaysAndSoDoesItsRemoval() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["computeHistory": ".verbinal/compute-history"]))
        let a = ComputeRunStore(persistence: nil), b = ComputeRunStore(persistence: nil)
        var run = ComputeRun(RunCodeContract.Request(id: "AB12-run", language: "python", code: "print(1)", timeout_seconds: 60),
                             author: .agent, submittedAt: Date(timeIntervalSince1970: 1_800_000_000))
        a.add(run)
        let syncA = sync(remote, [a.syncCollection().kind], device: "a")
        let syncB = sync(remote, [b.syncCollection().kind], device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)
        XCTAssertEqual(b.runs.map(\.id), ["AB12-run"])

        // Its result came to B: A has it at its next sync.
        run.status = "ok"
        run.exitCode = 0
        run.finishedAt = Date(timeIntervalSince1970: 1_800_000_100)
        b.keep(run)
        await syncB.sync(.changed)
        await syncA.sync(.asked)
        XCTAssertEqual(a.runs.first?.status, "ok")

        b.remove(id: "AB12-run")
        await syncB.sync(.changed)
        await syncA.sync(.asked)
        XCTAssertTrue(a.runs.isEmpty, "removed there, removed here, its capitals and all")
    }

    /// A one-letter rename keeps the file's size: its date says it changed.
    func testAChangeThatKeepsTheSizeIsFound() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["savedQueries": ".verbinal/queries"]))
        let a = queries(), b = queries()
        a.save(SavedQuery(name: "M31 a", adql: "SELECT 1"))
        let syncA = sync(remote, [a.syncCollection().kind], device: "a")
        let syncB = sync(remote, [b.syncCollection().kind], device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)
        b.rename(try XCTUnwrap(b.queries.first), to: "M31 b")
        await syncB.sync(.changed)
        await syncA.sync(.asked)
        XCTAssertEqual(a.queries.map(\.name), ["M31 b"])
    }

    /// Turned off on one device: the others stop sending it, and its files stay.
    func testACollectionTurnedOffOnOneDeviceStopsOnTheOthersAndItsFilesStay() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["savedQueries": ".verbinal/queries"]))
        let a = queries(), b = queries()
        a.save(SavedQuery(name: "from A", adql: "SELECT 1"))
        b.save(SavedQuery(name: "from B", adql: "SELECT 2"))
        let syncA = sync(remote, [a.syncCollection().kind], device: "a")
        let syncB = sync(remote, [b.syncCollection().kind], device: "b")
        await syncA.sync(.signedIn)
        await syncB.sync(.signedIn)
        let kept = await remote.files.keys.filter { $0.hasPrefix(".verbinal/queries/") }.count
        XCTAssertEqual(kept, 2)

        try await syncA.setDeclared(["savedQueries"], false)
        b.save(SavedQuery(name: "after", adql: "SELECT 3"))
        await syncB.sync(.changed)
        let after = await remote.files.keys.filter { $0.hasPrefix(".verbinal/queries/") }.count
        XCTAssertEqual(after, 2, "B sends nothing once A turned it off, and nothing is deleted")
        let onB = await syncB.status().kinds.first { $0.id == "savedQueries" }?.declared
        XCTAssertEqual(onB, false, "B reads the choice from the manifest")
    }

    // MARK: - The switches (plan 44, live: "I cannot turn on/off any of them")

    /// Two choices made at once: each read the manifest before the other
    /// wrote, and the second wrote over the first.
    func testTwoCollectionsTurnedOnAtOnceAreBothKept() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["exports": "Verbinal-Exports"]))
        let saved = queries(), recent = RecentSearchStore(fileName: "test-sync-recent-\(UUID().uuidString).json")
        let storage = sync(remote, [saved.syncCollection().kind, recent.syncCollection().kind, CountedKind.exports], device: "mac")
        async let one: Void = storage.setDeclared(["savedQueries"], true)
        async let two: Void = storage.setDeclared(["recentSearches"], true)
        _ = try await (one, two)
        let kept = try StorageManifest.decode(try await remote.read(StorageManifest.path))
        XCTAssertTrue(kept.declares("savedQueries"))
        XCTAssertTrue(kept.declares("recentSearches"))
        XCTAssertTrue(kept.declares("exports"), "and what was there stays")
    }

    /// Turned on while another sync runs, a collection had no first sync:
    /// "Waiting for its first sync" until something else started one.
    func testACollectionTurnedOnWhileASyncRunsHasItsFirstSyncAfterIt() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["savedQueries": ".verbinal/queries"]))
        let saved = queries(), recent = RecentSearchStore(fileName: "test-sync-recent-\(UUID().uuidString).json")
        saved.save(SavedQuery(name: "kept", adql: "SELECT 1"))
        recent.save(RecentSearch(name: "M31", formSnapshot: SearchFormSnapshot()))
        let storage = sync(remote, [saved.syncCollection().kind, recent.syncCollection().kind], device: "mac")
        await remote.hold(".verbinal/queries")
        let running = Task { await storage.sync(.signedIn) }
        await remote.whenHeld(".verbinal/queries")

        try await storage.setDeclared(["recentSearches"], true)
        let asked = Task { await storage.sync(.asked, only: "recentSearches") }
        try await Task.sleep(for: .milliseconds(300))
        await remote.release(".verbinal/queries")
        await running.value
        await asked.value
        let files = await remote.files.keys
        XCTAssertTrue(files.contains { $0.hasPrefix(".verbinal/recent-searches/") }, "its first sync came after the running one")
    }

    /// The switch shows the person's choice at once, not when the first
    /// sync ends; and that first sync comes after one already running.
    func testASwitchShowsTheChoiceAtOnce() async throws {
        let remote = FakeVOSpace()
        await remote.put(StorageManifest.path, manifest(["savedQueries": ".verbinal/queries"]))
        let saved = queries(), recent = RecentSearchStore(fileName: "test-sync-recent-\(UUID().uuidString).json")
        saved.save(SavedQuery(name: "kept", adql: "SELECT 1"))
        recent.save(RecentSearch(name: "M31", formSnapshot: SearchFormSnapshot()))
        let model = StorageSyncModel(tasks: TaskRegistry())
        model.attach(sync(remote, [saved.syncCollection().kind, recent.syncCollection().kind], device: "mac"))
        await remote.hold(".verbinal/queries")
        let running = model.run(.signedIn)
        await remote.whenHeld(".verbinal/queries")

        let choosing = model.setKeeps("recentSearches", true)
        XCTAssertTrue(model.keeps("recentSearches"), "on as soon as it is clicked")
        await remote.release(".verbinal/queries")
        await choosing?.value
        await running?.value
        XCTAssertTrue(model.keeps("recentSearches"))
        let files = await remote.files.keys
        XCTAssertTrue(files.contains { $0.hasPrefix(".verbinal/recent-searches/") })
    }

    // MARK: - Each area's store

    func testARecentSearchRunOnTwoDevicesIsOne() {
        let store = RecentSearchStore(fileName: "test-sync-recent-\(UUID().uuidString).json")
        var snapshot = SearchFormSnapshot()
        snapshot.target = "M31"
        store.save(RecentSearch(name: "M31", formSnapshot: snapshot))
        var theirs = RecentSearch(name: "M31 there", formSnapshot: snapshot)
        theirs.savedAt = Date().addingTimeInterval(60)
        store.keep(theirs)
        XCTAssertEqual(store.searches.map(\.name), ["M31 there"], "the newer stays")
        var older = RecentSearch(name: "M31 before", formSnapshot: snapshot)
        older.savedAt = Date().addingTimeInterval(-3600)
        store.keep(older)
        XCTAssertEqual(store.searches.map(\.name), ["M31 there"])
    }

    func testAWorkflowIsItsFile() throws {
        let folder = directory.appendingPathComponent("workflows")
        let store = WorkflowStore(directory: folder, builtins: { [] })
        let text = "# Survey\n> Find them.\n\n## Steps\n\n- [x] **Select** — the data.\n"
        store.keep(WorkflowFile(slug: "survey", text: text))
        XCTAssertEqual(store.files().map(\.slug), ["survey"])
        XCTAssertEqual(store.get("local:survey")?.document.steps.first?.done, true, "a step ticked there is ticked here")
        store.removeFile(slug: "survey")
        XCTAssertTrue(store.files().isEmpty)
    }

    func testGuidesAndDescriptionsAreKeptAndRemovedByName() throws {
        let guides = AIGuideService(database: try AppDatabase.makeInMemory())
        guides.keep(GuideEntry(kind: .guide, name: "claims_and_evidence", text: "How to report findings.", body: "Candidates, not confirmations."))
        guides.keep(GuideEntry(kind: .toolDescription, name: "run_code", text: "Runs on the person's allocation."))
        XCTAssertEqual(Set(guides.syncEntries().map(\.key)), ["guide:claims_and_evidence", "toolDescription:run_code"])
        guides.keep(GuideEntry(kind: .guide, name: "claims_and_evidence", text: "Changed there.", body: nil))
        XCTAssertEqual(guides.guides.map(\.description), ["Changed there."], "the same guide, by its name")
        guides.remove(.guide, named: "claims_and_evidence")
        guides.remove(.toolDescription, named: "run_code")
        XCTAssertTrue(guides.syncEntries().isEmpty)
        XCTAssertEqual(GuideEntry.parse(key: "toolDescription:get_fits_header")?.name, "get_fits_header")
        XCTAssertNil(GuideEntry.parse(key: "somethingNew:x"), "a kind this build does not know")
    }

    func testSessionInstructionsTravelOnlyWhenThePersonSetSome() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test-sync-\(UUID().uuidString)"))
        let approvals = SessionApprovals(defaults: defaults)
        XCTAssertTrue(approvals.syncEntries().isEmpty, "the built-in ones are every device's already")
        approvals.defaultInstructions = "Keep the work in CANFAR."
        let entry = try XCTUnwrap(approvals.syncEntries().first)
        XCTAssertEqual(entry.text, "Keep the work in CANFAR.")
        XCTAssertNotEqual(entry.modified, .distantPast)
    }

    func testAJobFromAnotherDeviceKeepsTheReasonThisMacHad() {
        let store = JobHistoryStore(persistence: nil)
        let reasoned = JobRecord(id: "j1", name: "fit", image: "x:1", origin: .user, outcome: .failed, status: "Failed",
                                 startedAt: "", finishedAt: Date(timeIntervalSince1970: 100), failureReason: "OOMKilled", targetImage: nil)
        store.record(reasoned)
        var theirs = reasoned
        theirs.failureReason = nil
        store.keep(theirs)
        XCTAssertEqual(store.jobs.first?.failureReason, "OOMKilled")
        store.remove(id: "j1")
        XCTAssertTrue(store.jobs.isEmpty)
    }

    func testALaunchNameIsOneRecentLaunch() {
        let store = RecentLaunchStore(fileName: "test-sync-launches-\(UUID().uuidString).json")
        store.save(RecentLaunch(name: "notebook-1", type: "notebook", image: "x:1"))
        var theirs = RecentLaunch(name: "notebook-1", type: "notebook", image: "x:2")
        theirs.launchedAt = Date().addingTimeInterval(60)
        store.keep(theirs)
        XCTAssertEqual(store.launches.map(\.image), ["x:2"])
    }

    func testPortalDefaultsKeepTheirDate() {
        let service = PortalSettingsService(fileName: "test-sync-portal-\(UUID().uuidString).json")
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        service.keep(PortalSettings(username: "me", defaultProject: "skaha", modifiedAt: then))
        XCTAssertEqual(service.settings(for: "me")?.modifiedAt, then)
        XCTAssertEqual(service.settings(for: "me")?.defaultProject, "skaha")
    }
}
