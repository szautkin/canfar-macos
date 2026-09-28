// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Images the platform's catalogue does not list: search the registry
/// behind it, and keep what is found in the user's own list, where it
/// joins the catalogue in the images card and on the launch form.

/// One image as an agent sees it, from the registry or the user's list.
struct RegistryImageEntry: Encodable, Sendable, Equatable {
    /// `host/project/name:tag` — as `launch_session.image` takes it.
    let id: String
    /// The session types its labels declare: the launch tabs that can offer it.
    let types: [String]
    let project: String
    /// When it joined the user's list; absent when it is not in it.
    let addedAt: String?
    /// False when no label names a session type: the Standard launch tab
    /// cannot offer it, and a launch must name the type itself.
    let launchableFromStandard: Bool
    let note: String?

    init(_ image: RegistryImage) {
        id = image.id
        types = image.types
        project = image.project
        addedAt = image.addedAt.map { ISO8601DateFormatter().string(from: $0) }
        launchableFromStandard = image.isOfferedOnStandard
        note = image.isOfferedOnStandard ? nil
            : "No session type in its labels, so the Standard launch tab cannot offer it: launch it with launch_session and a type you choose (the Advanced tab)."
    }
}

// MARK: - search_image_registry

struct SearchImageRegistryTool: JSONReadTool {
    /// Up to two dozen repositories, four at a time — a search can honestly take a while.
    var toolTimeoutSeconds: TimeInterval { 90 }

    struct Args: Decodable, Sendable { let query: String }

    struct Output: Encodable, Sendable {
        let query: String
        let count: Int
        let images: [RegistryImageEntry]
        let message: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "search_image_registry",
        description: "Search the container registry BEHIND the platform for images its catalogue does not list — a colleague's build, or a tag Skaha has not picked up. list_session_images is the curated catalogue and the place to look first; this is for when what you want is not in it. Each result carries the session types its registry labels declare (they decide which launch tab can offer it) and `addedAt` when it is already in the user's list. Keep one with add_registry_image. Uses the registry and credentials of Settings ▸ Image Discovery.",
        schema: #"""
        {
          "type": "object",
          "required": ["query"],
          "properties": {
            "query": { "type": "string", "description": "Repository name or part of it. An empty query is refused — it would mean the whole registry." }
          },
          "additionalProperties": false
        }
        """#
    )

    let search: @Sendable (String) async throws -> [RegistryImage]
    let mine: @Sendable () async -> [RegistryImage]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolFailureReason.invalidArgument("query is required — an empty search would be a request for the whole registry")
        }
        let found: [RegistryImage]
        do {
            found = try await search(query)
        } catch {
            throw ToolFailureReason.backendError(error.localizedDescription)
        }
        let added = Dictionary(await mine().map { ($0.id.lowercased(), $0.addedAt) }, uniquingKeysWith: { first, _ in first })
        let images = found.map { image in
            var entry = image
            entry.addedAt = added[image.id.lowercased()] ?? nil
            return RegistryImageEntry(entry)
        }
        return Output(query: query, count: images.count, images: images,
                      message: images.isEmpty ? "nothing in the registry matched that" : nil)
    }
}

// MARK: - list_my_images

struct ListMyImagesTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let count: Int
        let images: [RegistryImageEntry]
        let message: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_my_images",
        description: "The registry images the user added to their own list, newest first. They appear in the images card (its Added tab) and on the launch form beside the platform's catalogue, and list_session_images includes them.",
        schema: #"""
        { "type": "object", "properties": {}, "additionalProperties": false }
        """#
    )

    let mine: @Sendable () async -> [RegistryImage]

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        let images = await mine().map(RegistryImageEntry.init)
        return Output(count: images.count, images: images,
                      message: images.isEmpty ? "the user has not added any images" : nil)
    }
}

// MARK: - add_registry_image

struct AddRegistryImageTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let imageID: String
        var types: [String]?
    }

    /// The types travel with the proposal: by the time it is applied the
    /// search that found them is over, and an image without them is one
    /// no launch tab can offer.
    struct Payload: Codable, Sendable, Equatable {
        let imageID: String
        let types: [String]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "add_registry_image",
        description: "Propose adding a registry image to the user's own list, where it joins the platform's catalogue in the images card and on the launch form. Use the id exactly as search_image_registry reported it — a reference the registry does not have cannot be launched — and pass the `types` it reported: they decide which launch tab can offer it. One already in the list is left as it is.",
        schema: #"""
        {
          "type": "object",
          "required": ["imageID"],
          "properties": {
            "imageID": { "type": "string", "description": "Full reference: host/project/name:tag." },
            "types": { "type": "array", "items": { "type": "string" }, "description": "Session types from search_image_registry." }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let id = RegistryImage.normalized(args.imageID)
        if let problem = RegistryImage.problem(with: id) { throw ToolFailureReason.invalidArgument(problem) }
        let image = RegistryImage(id: id, labels: args.types ?? [])
        return try ProposalPlan.encoding(
            kind: "add_registry_image",
            summary: "Add image \(id) to your images",
            payload: Payload(imageID: image.id, types: image.types))
    }
}

struct AddRegistryImageApplier: ResultReportingApplier {
    let kind = "add_registry_image"
    /// Adds the image; false when it was already in the list.
    let add: @Sendable (RegistryImage) async -> Bool
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(AddRegistryImageTool.Payload.self, from: proposal.payload)
        let added = await add(RegistryImage(id: payload.imageID, types: payload.types))
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        let extra = AutoAppliedAck.Extra(id: payload.imageID, note: added ? nil : "already in the user's images — left as it was")
        return (try? JSONEncoder().encode(extra)) ?? Data()
    }
}

// MARK: - remove_registry_image (destructive)

struct RemoveRegistryImageTool: JSONWriteTool {
    /// It deletes only a list entry — the image can be found again — but
    /// the list is the user's curation, and taking from it unasked is the
    /// small liberty that stops a list being trusted.
    static let verbClass: VerbClass = .destructive

    struct Args: Codable, Sendable { let imageID: String }
    typealias Payload = Args

    let definition = AIToolDefinition.withStaticSchema(
        name: "remove_registry_image",
        description: "Propose removing an image from the user's own list (list_my_images). The image itself is untouched — search_image_registry finds it again.",
        schema: #"""
        {
          "type": "object",
          "required": ["imageID"],
          "properties": { "imageID": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let isListed: @Sendable (String) async -> Bool

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        let id = RegistryImage.normalized(args.imageID)
        guard !id.isEmpty else { throw ToolFailureReason.invalidArgument("imageID is required") }
        guard await isListed(id) else {
            throw ToolFailureReason.unknownTarget("'\(id)' is not in the user's images — see list_my_images")
        }
        return try ProposalPlan.encoding(
            kind: "remove_registry_image",
            summary: "Remove image \(id) from your images",
            payload: Payload(imageID: id))
    }
}

struct RemoveRegistryImageApplier: ProposalApplier {
    let kind = "remove_registry_image"
    /// Removes the image; false when it was not in the list.
    let remove: @Sendable (String) async -> Bool
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(RemoveRegistryImageTool.Payload.self, from: proposal.payload)
        guard await remove(payload.imageID) else {
            throw ProposalApplyError.backendError("'\(payload.imageID)' is no longer in the user's images")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
    }
}
