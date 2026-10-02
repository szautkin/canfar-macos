// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import os
import VerbinalKit
@testable import Verbinal

/// Plan 30 A6: what an assistant made is told apart, so removing it can be
/// allowed while removing what the person made asks.
@MainActor
final class AssistantMadeTests: XCTestCase {

    private func proposal(_ tool: String, _ fields: [String: Any]) -> PendingProposal {
        PendingProposal(toolName: tool, kind: tool, summary: tool,
                        payload: try! JSONSerialization.data(withJSONObject: fields), origin: .external(clientID: "test"))
    }

    private func answer(id: String? = nil, succeeded: [String]? = nil) -> Data {
        try! JSONEncoder().encode(AutoAppliedAck.Extra(id: id, succeeded: succeeded))
    }

    func testWhatEachChangeMakesAndRemoves() {
        let me = "qa"
        XCTAssertEqual(AssistantMade.made(by: proposal("save_query", ["id": "Q1", "name": "n"]), result: nil, username: me),
                       ["savedQuery:Q1"])
        XCTAssertEqual(AssistantMade.made(by: proposal("create_vospace_folder", ["parentPath": "", "folderName": "qa-full"]),
                                          result: nil, username: me), ["vospace:qa-full"])
        XCTAssertEqual(AssistantMade.made(by: proposal("upload_text_to_vospace", ["vospacePath": "/home/qa/qa-full/notes.txt", "content": "x"]),
                                          result: nil, username: me), ["vospace:qa-full/notes.txt"], "the path from home, as Storage reads it")
        XCTAssertEqual(AssistantMade.made(by: proposal("launch_session", ["name": "nb"]), result: answer(id: "abc123"), username: me),
                       ["session:abc123"])
        XCTAssertEqual(AssistantMade.made(by: proposal("download_observations_bulk", [:]), result: answer(succeeded: ["R1", "R2"]),
                                          username: me), ["research:R1", "research:R2"])
        XCTAssertEqual(AssistantMade.removed(by: proposal("delete_vospace_node", ["path": "qa-full", "recursive": true]), username: me),
                       ["vospace:qa-full"])
        XCTAssertEqual(AssistantMade.removed(by: proposal("delete_session", ["id": "abc123"]), username: me), ["session:abc123"])
        XCTAssertNil(AssistantMade.removed(by: proposal("clear_user_site", [:]), username: me))
    }

    private func resolver(made: Set<String>, subtree: [String: [String]] = [:], existing: Set<String> = [],
                          vospaceAnswers: Bool = true) -> ChangeKindResolver {
        ChangeKindResolver(username: "qa",
                           isMade: { made.contains($0) },
                           subtree: { vospaceAnswers ? (subtree[$0] ?? []) : nil },
                           exists: { vospaceAnswers ? existing.contains($0) : nil })
    }

    func testARemovalOfOnlyWhatAnAssistantMadeIsThatKind() async {
        let made = resolver(made: ["savedQuery:Q1"])
        let mine = await made.kind(of: proposal("delete_saved_query", ["id": "Q1"]))
        XCTAssertEqual(mine, .removeAssistantMade)
        let theirs = await made.kind(of: proposal("delete_saved_query", ["id": "Q9"]))
        XCTAssertEqual(theirs, .removeNotesAndSaved, "the person's query: their own kind, which asks")
        let everything = await resolver(made: []).kind(of: proposal("clear_user_site", [:]))
        XCTAssertEqual(everything, .everythingAtOnce)
    }

    /// A folder goes with everything in it: it is an assistant's only when
    /// everything under it is.
    func testAFolderIsAnAssistantsOnlyWithAllInIt() async {
        let delete = proposal("delete_vospace_node", ["path": "qa-full", "recursive": true])
        let all = resolver(made: ["vospace:qa-full", "vospace:qa-full/notes.txt"], subtree: ["qa-full": ["qa-full/notes.txt"]])
        let allKind = await all.kind(of: delete)
        XCTAssertEqual(allKind, .removeAssistantMade)
        let mixed = resolver(made: ["vospace:qa-full", "vospace:qa-full/notes.txt"],
                             subtree: ["qa-full": ["qa-full/notes.txt", "qa-full/thesis.pdf"]])
        let mixedKind = await mixed.kind(of: delete)
        XCTAssertEqual(mixedKind, .removeFromStorage, "the person's file inside it")
        let unknown = resolver(made: ["vospace:qa-full"], vospaceAnswers: false)
        let unknownKind = await unknown.kind(of: delete)
        XCTAssertEqual(unknownKind, .removeFromStorage, "VOSpace cannot say: it asks")
    }

    func testAnUploadOverAFileReplacesIt() async {
        let upload = proposal("upload_text_to_vospace", ["vospacePath": "qa-full/notes.txt", "content": "x"])
        let new = await resolver(made: []).kind(of: upload)
        XCTAssertEqual(new, .addToStorage)
        let overTheirs = await resolver(made: [], existing: ["qa-full/notes.txt"]).kind(of: upload)
        XCTAssertEqual(overTheirs, .removeFromStorage)
        let overMine = await resolver(made: ["vospace:qa-full/notes.txt"], existing: ["qa-full/notes.txt"]).kind(of: upload)
        XCTAssertEqual(overMine, .removeAssistantMade)
        let unknown = await resolver(made: [], vospaceAnswers: false).kind(of: upload)
        XCTAssertEqual(unknown, .removeFromStorage, "cannot tell: it may write over a file")
    }

    func testTheStoreKeepsWhatWasMadeAndForgetsWhatWasRemoved() throws {
        let folder = "VerbinalTests-\(UUID().uuidString)"
        let persistence = DiskPersistence<[AssistantMadeStore.Entry]>(subdirectory: folder, fileName: "made.json",
                                                                      logger: Logger(subsystem: "tests", category: "made"))
        let store = AssistantMadeStore(persistence: persistence)
        store.applied(proposal("save_query", ["id": "Q1"]), result: nil, username: "qa")
        XCTAssertTrue(store.contains("savedQuery:Q1"))
        XCTAssertTrue(AssistantMadeStore(persistence: persistence).contains("savedQuery:Q1"), "kept on this Mac")
        store.applied(proposal("delete_saved_query", ["id": "Q1"]), result: nil, username: "qa")
        XCTAssertFalse(store.contains("savedQuery:Q1"))
    }

    /// With the default setting, removing what an assistant made applies at
    /// once and removing the person's waits — and each says why.
    func testTheDecisionFollowsWhatItActsOn() {
        let made = ChangeCatalog.decision(kind: .removeAssistantMade, permissions: .defaults)
        XCTAssertTrue(made.appliesAtOnce)
        XCTAssertEqual(made.rule, "applied at once: the person allows \"Remove what an assistant made\"")
        let theirs = ChangeCatalog.decision(kind: .removeFromStorage, permissions: .defaults)
        XCTAssertFalse(theirs.appliesAtOnce)
        XCTAssertEqual(AgentsService.waitingRule(proposal("delete_vospace_node", ["path": "x"]), kind: .removeAssistantMade,
                                                 permissions: .askForEverything),
                       "waits in Pending: the person asks to approve \"Remove what an assistant made\"")
    }
}
