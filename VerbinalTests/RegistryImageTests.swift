// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
import VerbinalKit
@testable import Verbinal

/// Images the catalogue does not list: what the registry says of them, the
/// person's own list, the search, and the agents' tools.
@MainActor
final class RegistryImageTests: XCTestCase {

    // MARK: - The image

    func testOnlyLabelsThatNameASessionTypeBecomeTypes() {
        let image = RegistryImage(id: "h/p/n:1", labels: ["Notebook", "gpu", " headless ", "notebook", "desktop-app"])
        XCTAssertEqual(image.types, ["notebook", "headless", "desktop-app"])
        XCTAssertEqual(image.project, "p")
    }

    func testAReferenceNeedsATagEvenOnAHostWithAPort() {
        XCTAssertNil(RegistryImage.problem(with: "images.canfar.net/skaha/astroml:24.07"))
        XCTAssertNotNil(RegistryImage.problem(with: "images.canfar.net/skaha/astroml"))
        XCTAssertNotNil(RegistryImage.problem(with: "localhost:5000/me/tool"), "the host's port is not a tag")
        XCTAssertNotNil(RegistryImage.problem(with: ""))
    }

    func testAPastedReferenceLosesItsSchemeAndSpaces() {
        XCTAssertEqual(RegistryImage.normalized(" https:// images.canfar.net/skaha/x:1 \n"), "images.canfar.net/skaha/x:1")
        XCTAssertEqual(RegistryImage.normalized("images.canfar.net"), "images.canfar.net")
    }

    // MARK: - The list

    func testTheListIsNewestFirstOnceEachAndRemovable() {
        let store = UserImageStore(persistence: nil)
        XCTAssertTrue(store.add(RegistryImage(id: "h/p/a:1", types: ["notebook"])))
        XCTAssertTrue(store.add(RegistryImage(id: "h/p/b:1", types: [])))
        XCTAssertFalse(store.add(RegistryImage(id: "H/P/A:1", types: [])), "already there, whatever the case")
        XCTAssertFalse(store.add(RegistryImage(id: "h/p/untagged", types: [])), "no tag, no entry")
        XCTAssertEqual(store.images.map(\.id), ["h/p/b:1", "h/p/a:1"])
        XCTAssertNotNil(store.images[0].addedAt)

        XCTAssertTrue(store.remove("h/p/a:1"))
        XCTAssertFalse(store.remove("h/p/a:1"))
        XCTAssertEqual(store.images.map(\.id), ["h/p/b:1"])
    }

    func testTheListStopsAtItsCeilingDroppingTheOldest() {
        let store = UserImageStore(persistence: nil)
        for index in 0...UserImageStore.maxImages { store.add(RegistryImage(id: "h/p/i:\(index)", types: [])) }
        XCTAssertEqual(store.images.count, UserImageStore.maxImages)
        XCTAssertEqual(store.images.first?.id, "h/p/i:\(UserImageStore.maxImages)")
        XCTAssertFalse(store.contains("h/p/i:0"))
    }

    func testAddedImagesFollowTheCatalogueWithoutRepeatingIt() {
        let catalogue = [RawImage(id: "h/skaha/a:1", types: ["notebook"])]
        let mine = [RegistryImage(id: "h/me/tool:2", types: ["headless"]), RegistryImage(id: "H/SKAHA/A:1", types: [])]
        XCTAssertEqual(UserImageStore.merged(mine, into: catalogue).map(\.id), ["h/skaha/a:1", "h/me/tool:2"])
        XCTAssertEqual(UserImageStore.merged(mine, into: catalogue).last?.types, ["headless"])
    }

    // MARK: - The search

    private struct Stub: @unchecked Sendable {
        let routes: [String: (Int, String)]
        let seen = Box()

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var requests: [URLRequest] = []
            func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
            var all: [URLRequest] { lock.withLock { requests } }
        }

        func search() -> RegistrySearch {
            RegistrySearch { request in
                seen.append(request)
                let url = request.url?.absoluteString ?? ""
                guard let (code, body) = routes.first(where: { url.contains($0.key) })?.value else { throw URLError(.cannotFindHost) }
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    func testASearchReadsEachRepositorysTagsAndLabelsSkippingWhatItCannot() async throws {
        let stub = Stub(routes: [
            "/api/v2.0/search?q=astro": (200, #"{"repository":[{"project_name":"skaha","repository_name":"skaha/base/astro"},{"project_name":"secret","repository_name":"secret/astro"},{"project_name":"me","repository_name":"me/astro"}]}"#),
            "/projects/skaha/repositories/base%252Fastro/artifacts": (200, #"[{"tags":[{"name":"2"},{"name":"1"}],"labels":[{"name":"notebook"},{"name":"gpu"}]},{"tags":null,"labels":[]}]"#),
            "/projects/secret/repositories/astro/artifacts": (403, "{}"),
            "/projects/me/repositories/astro/artifacts": (200, #"[{"tags":[{"name":"1"}],"labels":[{"name":"skaha/headless"}]}]"#),
        ])
        let found = try await stub.search().search(host: "https://images.example.org/", query: " astro ", basic: "dTpz")
        XCTAssertEqual(found.map(\.id), ["images.example.org/me/astro:1", "images.example.org/skaha/base/astro:1", "images.example.org/skaha/base/astro:2"],
                       "untagged skipped, the refused repository skipped, sorted")
        XCTAssertEqual(found.last?.types, ["notebook"])
        XCTAssertEqual(found.first?.types, [], "a label that names no session type is no type")
        XCTAssertTrue(stub.seen.all.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Basic dTpz" })
        XCTAssertTrue(stub.seen.all.contains { $0.url?.query?.contains("with_label=true") == true })
    }

    func testASearchSaysWhatWentWrong() async {
        func failure(_ host: String, _ query: String, _ routes: [String: (Int, String)]) async -> RegistrySearchError? {
            do {
                _ = try await Stub(routes: routes).search().search(host: host, query: query, basic: nil)
                return nil
            } catch {
                return error
            }
        }
        let empty = await failure("h", "  ", [:])
        XCTAssertEqual(empty, .emptyQuery)
        let noHost = await failure(" ", "x", [:])
        XCTAssertEqual(noHost, .noHost)
        let rejected = await failure("h", "x", ["search": (401, "")])
        XCTAssertEqual(rejected, .rejected)
        XCTAssertTrue(rejected?.localizedDescription.contains("CLI secret") == true)
        let broken = await failure("h", "x", ["search": (500, "")])
        XCTAssertEqual(broken, .status(500))
        let garbled = await failure("h", "x", ["search": (200, "<html>")])
        guard case .unreadable = garbled else { return XCTFail("\(String(describing: garbled))") }
        let unreachable = await failure("h", "x", [:])
        guard case .unreachable = unreachable else { return XCTFail("\(String(describing: unreachable))") }
    }

    func testTheSearchModelShowsResultsAndKeepsWhatIsAdded() async {
        let store = UserImageStore(persistence: nil)
        let model = RegistrySearchModel(store: store) { query throws(RegistrySearchError) in
            guard query == "astro" else { throw .rejected }
            return [RegistryImage(id: "h/p/astro:1", types: [])]
        }
        XCTAssertFalse(model.canSearch)
        model.query = " astro "
        await model.run()
        XCTAssertEqual(model.phase, .found)
        XCTAssertEqual(model.searched, "astro")
        model.add(model.results[0])
        XCTAssertTrue(model.isAdded(model.results[0]))
        XCTAssertTrue(RegistrySearchModel.typesLine(model.results[0]).contains("Advanced"))

        model.query = "other"
        await model.run()
        guard case .failed(let message) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(message.contains("CLI secret"))
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(store.images.map(\.id), ["h/p/astro:1"])
    }

    // MARK: - The images card

    func testTheCardShowsAddedImagesInTheirOwnTabAndInTheirTypes() async {
        let store = UserImageStore(persistence: nil)
        let card = CanfarImagesModel(imageService: ImageService(network: NetworkClient(session: .shared)), coordinator: nil,
                                     recentLaunchStore: RecentLaunchStore(), portalSettingsService: PortalSettingsService(),
                                     userImages: store, username: "u")
        store.add(RegistryImage(id: "h/me/tool:1", types: ["headless"]))
        store.add(RegistryImage(id: "h/me/bare:1", types: []))
        XCTAssertEqual(card.addedImageIDs, ["h/me/bare:1", "h/me/tool:1"])
        await card.addedImagesChanged()
        XCTAssertEqual(card.count(for: .mine), 2)
        XCTAssertEqual(card.count(for: .headless), 1)
        card.selectedTab = .mine
        XCTAssertEqual(Set(card.filteredRows.map(\.id)), ["h/me/bare:1", "h/me/tool:1"], "one naming no type still has a place")
    }

    // MARK: - The tools

    private let ctx = AIToolContext(origin: .external(clientID: "t"), proposals: InMemoryProposalStore(), budget: ProposalBudget(limit: 9))

    private func output<T: Decodable>(_ result: ToolResult, as type: T.Type) throws -> T {
        guard case .data(let data) = result else { throw NSError(domain: "\(result)", code: 0) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct Listing: Decodable {
        let count: Int
        let images: [Entry]
        let message: String?
        struct Entry: Decodable { let id: String; let types: [String]; let project: String; let addedAt: String? }
    }

    func testTheRegistrySearchToolSaysWhichAreAlreadyTheUsers() async throws {
        let added = RegistryImage(id: "h/p/a:1", types: [], addedAt: Date(timeIntervalSince1970: 0))
        let tool = SearchImageRegistryTool(
            search: { _ in [RegistryImage(id: "H/P/A:1", types: ["notebook"]), RegistryImage(id: "h/p/b:1", types: [])] },
            mine: { [added] })
        let found = try output(await tool.invoke(arguments: Data(#"{"query":"a"}"#.utf8), context: ctx), as: Listing.self)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.images.map(\.addedAt), ["1970-01-01T00:00:00Z", nil])
        XCTAssertEqual(found.images[0].project, "P")

        guard case .failed(.invalidArgument) = await tool.invoke(arguments: Data(#"{"query":" "}"#.utf8), context: ctx) else { return XCTFail() }
        let failing = SearchImageRegistryTool(search: { _ in throw RegistrySearchError.rejected }, mine: { [] })
        guard case .failed(.backendError(let why)) = await failing.invoke(arguments: Data(#"{"query":"a"}"#.utf8), context: ctx) else { return XCTFail() }
        XCTAssertTrue(why.contains("CLI secret"))
    }

    func testListingMyImagesSaysWhenThereAreNone() async throws {
        let none = try output(await ListMyImagesTool(mine: { [] }).invoke(arguments: Data("{}".utf8), context: ctx), as: Listing.self)
        XCTAssertEqual(none.count, 0)
        XCTAssertNotNil(none.message)
    }

    func testAddingPlansATaggedReferenceWithItsSessionTypes() async throws {
        let plan = try await AddRegistryImageTool().plan(.init(imageID: "https://h/p/a:1", types: ["Notebook", "gpu"]), context: ctx)
        let payload = try JSONDecoder().decode(AddRegistryImageTool.Payload.self, from: plan.payload)
        XCTAssertEqual(payload, .init(imageID: "h/p/a:1", types: ["notebook"]))
        XCTAssertEqual(AddRegistryImageTool.verbClass, .semanticWrite)
        do {
            _ = try await AddRegistryImageTool().plan(.init(imageID: "h/p/a"), context: ctx)
            XCTFail("no tag")
        } catch {}

        let store = UserImageStore(persistence: nil)
        let applier = AddRegistryImageApplier(add: { image in await store.add(image) },
                                              activity: AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let proposal = PendingProposal(toolName: "add_registry_image", kind: "add_registry_image", summary: plan.summary,
                                       payload: plan.payload, origin: .external(clientID: "t"))
        let first = try JSONDecoder().decode(AutoAppliedAck.Extra.self, from: try await applier.applyReturningResult(proposal))
        XCTAssertNil(first.note)
        XCTAssertEqual(store.images.map(\.types), [["notebook"]])
        let again = try JSONDecoder().decode(AutoAppliedAck.Extra.self, from: try await applier.applyReturningResult(proposal))
        XCTAssertNotNil(again.note, "already there — said, not failed")
    }

    func testRemovingWaitsForThePersonAndOnlyWhatIsListed() async throws {
        XCTAssertEqual(RemoveRegistryImageTool.verbClass, .destructive)
        let store = UserImageStore(persistence: nil)
        store.add(RegistryImage(id: "h/p/a:1", types: []))
        let tool = RemoveRegistryImageTool(isListed: { id in await store.contains(id) })
        do {
            _ = try await tool.plan(.init(imageID: "h/p/zzz:1"), context: ctx)
            XCTFail("not in the list")
        } catch ToolFailureReason.unknownTarget {}

        let plan = try await tool.plan(.init(imageID: "h/p/a:1"), context: ctx)
        let applier = RemoveRegistryImageApplier(remove: { id in await store.remove(id) },
                                                 activity: AgentActivityStore(fileName: "test-activity-\(UUID().uuidString).json"))
        let proposal = PendingProposal(toolName: "remove_registry_image", kind: "remove_registry_image", summary: plan.summary,
                                       payload: plan.payload, origin: .external(clientID: "t"))
        try await applier.apply(proposal)
        XCTAssertTrue(store.images.isEmpty)
        do {
            try await applier.apply(proposal)
            XCTFail("gone already")
        } catch {}
    }
}
