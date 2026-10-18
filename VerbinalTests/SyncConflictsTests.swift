// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import MCPCore
import VerbinalKit
@testable import Verbinal

/// Plan 45 F4: what the person decides — told on the bar, chosen either way
/// through the app as Settings ▸ Storage chooses it, and by an assistant as
/// a proposal of the kind of what it does.
@MainActor
final class SyncConflictsTests: XCTestCase {
    typealias FakeVOSpace = StorageSyncTests.FakeVOSpace
    typealias FakeResearch = StorageSyncTests.FakeResearch

    private var directory: URL!
    private let key = "ivo://cadc.nrc.ca/CFHT?1525350/1525350p"
    private var path: String { ".verbinal/research/" + ResearchItem.fileName(for: key) }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("conflicts-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func catalog(_ research: FakeResearch) -> StorageKindCatalog {
        StorageKindCatalog(kinds: [CollectionKind(id: "research", defaultFolder: ".verbinal/research", collection: research)])
    }

    private func item(note: String = "first", target: String = "M31") -> ResearchItem {
        ResearchItem(recordKey: key, changedAt: Date(timeIntervalSince1970: 100),
                     details: .init(publisherID: key, collection: "CFHT", observationID: "1525350", targetName: target,
                                    instrument: "MegaPrime", filter: "r", ra: "", dec: "", startDate: "", calLevel: "2"),
                     note: .init(text: note, rating: 3, tags: ["usable"]))
    }

    private func revision(_ remote: FakeVOSpace) async throws -> SyncRevision {
        SyncRevision(of: try ResearchItem.decode(try await remote.read(path)))
    }

    /// This Mac as the app has it — the model hearing its sync, on a bar of
    /// its own — and another device, both synced once with the record.
    private func devices() async -> (remote: FakeVOSpace, registry: TaskRegistry, model: StorageSyncModel,
                                     a: FakeResearch, b: FakeResearch, syncB: StorageSync) {
        let remote = FakeVOSpace()
        let manifest = #"{ "format": "verbinal.vospace-manifest", "version": 1, "kinds": { "research": { "folder": ".verbinal/research", "format": 1, "since": "2026-10-17T12:00:00Z" } } }"#
        await remote.put(StorageManifest.path, Data(manifest.utf8))
        let a = FakeResearch(), b = FakeResearch()
        await a.set(item())
        let registry = TaskRegistry()
        let model = StorageSyncModel(tasks: registry)
        model.attach(StorageSync(remote: remote, catalog: catalog(a), stateFile: directory.appendingPathComponent("state-a.json"),
                                 watcher: { [weak model] event in await model?.heard(event) }))
        let syncB = StorageSync(remote: remote, catalog: catalog(b), stateFile: directory.appendingPathComponent("state-b.json"))
        await model.run(.signedIn)?.value
        await syncB.sync(.signedIn)
        return (remote, registry, model, a, b, syncB)
    }

    /// The same note changed on both: storage's (B's) stays, this Mac's waits.
    private func bothChanged() async throws -> (FakeVOSpace, TaskRegistry, StorageSyncModel, FakeResearch, FakeResearch, StorageSync, SyncConflict) {
        let (remote, registry, model, a, b, syncB) = await devices()
        await b.set(item(note: "from B"))
        await syncB.sync(.changed)
        await a.set(item(note: "from A"))
        await model.run(.changed)?.value
        let conflict = try XCTUnwrap(model.conflicts.first, "a conflict waits")
        XCTAssertEqual(conflict.reason, .bothChanged)
        return (remote, registry, model, a, b, syncB, conflict)
    }

    // MARK: - On the bar

    func testASyncThatLeavesAConflictSaysSoOnTheBar() async throws {
        let (_, registry, _, _, _, _, _) = try await bothChanged()
        let task = try XCTUnwrap(registry.tasks.last { $0.label == "Syncing with your storage" },
                                 "a sync that moved one item is on the bar when it leaves something to choose")
        XCTAssertEqual(task.progress, .succeeded)
        XCTAssertTrue(task.message?.contains("1 to choose in Settings ▸ Storage") == true, task.message ?? "")
    }

    /// Live, F3: the conflict named the saved query by this Mac's name,
    /// "qa44 here", while the list showed storage's, "qa44 other".
    func testAConflictIsNamedAsItReadsHereNow() async throws {
        let (_, _, model, a, b, syncB) = await devices()
        await b.set(item(target: "M31 from B"))
        await syncB.sync(.changed)
        await a.set(item(target: "M31 from A"))
        await model.run(.changed)?.value
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.title, "M31 from B", "storage's name, as it reads here now")
        XCTAssertEqual(conflict.fields.map(\.field), ["details.targetName"])
        let here = await a.records[key]?.details.targetName
        XCTAssertEqual(here, "M31 from B")
    }

    // MARK: - Chosen either way

    func testKeepingThisMacsSendsItAsANewRevision() async throws {
        let (remote, _, model, a, b, syncB, conflict) = try await bothChanged()
        let before = try await revision(remote)
        await model.resolve(conflict.id, choosing: .mine)?.value
        let after = try await revision(remote)
        XCTAssertEqual(after.rev, before.rev + 1, "written as a new revision")
        let onA = await a.records[key]?.note?.text
        XCTAssertEqual(onA, "from A")
        XCTAssertTrue(model.conflicts.isEmpty, "not asked again")
        await syncB.sync(.asked)
        let onB = await b.records[key]?.note?.text
        XCTAssertEqual(onB, "from A", "and every device has it")
    }

    func testKeepingTheOthersWritesNothing() async throws {
        let (remote, _, model, a, _, _, conflict) = try await bothChanged()
        let before = try await revision(remote)
        await model.resolve(conflict.id, choosing: .theirs)?.value
        let after = try await revision(remote)
        XCTAssertEqual(after, before, "storage's is already every device's")
        let onA = await a.records[key]?.note?.text
        XCTAssertEqual(onA, "from B")
        XCTAssertTrue(model.conflicts.isEmpty)
    }

    /// Removed here, changed there: it came back. Remove It removes it
    /// everywhere; OK keeps it, writing nothing.
    func testARemovalNoticeRemovesItOrKeepsIt() async throws {
        let top: URL = directory
        defer { directory = top }
        for removing in [true, false] {
            // Each pass its own devices: nothing kept from the one before.
            directory = top.appendingPathComponent(removing ? "removing" : "keeping", isDirectory: true)
            let (remote, _, model, a, b, syncB) = await devices()
            await b.set(item(note: "changed on B"))
            await syncB.sync(.changed)
            await a.drop(key)
            await model.run(.changed)?.value
            let conflict = try XCTUnwrap(model.conflicts.first)
            XCTAssertEqual(conflict.reason, .removedHere)
            let before = try await revision(remote)
            await model.resolve(conflict.id, choosing: removing ? conflict.removing : conflict.keeping)?.value
            XCTAssertTrue(model.conflicts.isEmpty)
            await syncB.sync(.asked)
            let onA = await a.records[key], onB = await b.records[key]
            if removing {
                XCTAssertNil(onA, "removed here")
                XCTAssertNil(onB, "and on the other device")
            } else {
                XCTAssertEqual(onA?.note?.text, "changed on B", "kept, with its change")
                XCTAssertEqual(onB?.note?.text, "changed on B")
                let after = try await revision(remote)
                XCTAssertEqual(after, before, "nothing written")
            }
        }
    }

    // MARK: - For an assistant

    private var context: AIToolContext { AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget()) }

    private func conflict(_ reason: SyncConflict.Reason, kind: String = "research") -> SyncConflict {
        SyncConflict(kind: kind, key: key, fileName: "m31.json", title: "the Research record M31", reason: reason,
                     fields: reason == .bothChanged
                        ? [SyncMerge.Conflict(path: ["note", "text"], mine: .string("from A"), theirs: .string("from B"))] : [],
                     otherDevice: "Lab Mac", otherChangedAt: nil, at: Date())
    }

    private func proposed(_ conflict: SyncConflict, _ choice: String) async throws -> PendingProposal {
        let plan = try await ResolveSyncConflictTool(conflicts: { [conflict] })
            .plan(.init(id: conflict.id, choice: choice), context: context)
        return PendingProposal(toolName: "resolve_sync_conflict", kind: plan.kind, summary: plan.summary,
                               payload: plan.payload, origin: .external(clientID: "t"))
    }

    func testTheListSaysEachSideAndWhatEachChoiceDoes() async throws {
        let one = conflict(.bothChanged)
        let out = try await ListSyncConflictsTool(conflicts: { [one] }).handle(.init(), context: context)
        let listed = try XCTUnwrap(out.conflicts.first)
        XCTAssertEqual(listed.id, "research/m31.json")
        XCTAssertEqual(listed.reason, "bothChanged")
        XCTAssertEqual(listed.otherDevice, "Lab Mac")
        XCTAssertEqual(listed.fields.first?.field, "note.text")
        XCTAssertEqual(listed.fields.first?.thisMac, .string("from A"))
        XCTAssertEqual(listed.fields.first?.storage, .string("from B"))
        XCTAssertTrue(listed.mine.hasPrefix("Keep This Mac's"), listed.mine)
        XCTAssertTrue(listed.says.contains("Lab Mac"), listed.says)
    }

    func testAChoiceIsProposedAsTheKindOfWhatItDoes() async throws {
        let keep = try await proposed(conflict(.bothChanged), "mine")
        XCTAssertEqual(ChangeCatalog.kind(of: keep), .notesAndSaved)
        XCTAssertTrue(keep.summary.contains("Keep This Mac's"), keep.summary)
        let remove = try await proposed(conflict(.removedHere), "mine")
        XCTAssertEqual(ChangeCatalog.kind(of: remove), .removeNotesAndSaved, "a choice that removes is a removal")
        let ok = try await proposed(conflict(.removedHere), "theirs")
        XCTAssertEqual(ChangeCatalog.kind(of: ok), .notesAndSaved)
        let guide = try await proposed(conflict(.bothChanged, kind: "guides"), "mine")
        XCTAssertEqual(ChangeCatalog.kind(of: guide), .standingInstruction, "what every assistant is told always waits")
    }

    func testAnUnknownConflictOrChoiceIsRefusedWhenAsked() async throws {
        let tool = ResolveSyncConflictTool(conflicts: { [] })
        do {
            _ = try await tool.plan(.init(id: "research/gone.json", choice: "mine"), context: context)
            XCTFail("refused")
        } catch {
            XCTAssertTrue("\(error)".contains("list_sync_conflicts"), "\(error)")
        }
        let one = conflict(.bothChanged)
        do {
            _ = try await ResolveSyncConflictTool(conflicts: { [one] }).plan(.init(id: one.id, choice: "both"), context: context)
            XCTFail("refused")
        } catch {
            XCTAssertTrue("\(error)".contains("mine or theirs"), "\(error)")
        }
    }

    func testListStorageKindsCountsTheConflicts() {
        var status = StorageSync.Status(hasStorage: true, hasManifest: true, kinds: [], lastSync: nil, lastFailure: nil, running: false)
        status.kinds = [StorageSync.KindStatus(id: "research", declared: true, folder: ".verbinal/research", items: 1, bytes: 1,
                                               lastSync: nil, imported: 0, sent: 0, note: nil, failure: nil)]
        status.conflicts = [conflict(.bothChanged), conflict(.removedHere, kind: "workflows")]
        let out = StorageKindsOut(status)
        XCTAssertEqual(out.conflicts, 2)
        XCTAssertEqual(out.kinds.first?.conflicts, 1)
    }
}
