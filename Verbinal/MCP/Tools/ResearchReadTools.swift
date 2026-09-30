// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - list_downloaded_observations

/// Inventory of locally-downloaded observations. Optional filter by
/// collection.
struct ListDownloadedObservationsTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        var collection: String?
    }

    struct Output: Encodable, Sendable {
        let entries: [Entry]
        struct Entry: Encodable, Sendable {
            let id: String
            let publisherID: String
            let collection: String
            let observationID: String
            let targetName: String
            let instrument: String
            let filter: String
            let calLevel: String
            /// Research keeps a usable file for it; false for one kept
            /// without, and for one whose file has a `fileProblem`.
            let downloaded: Bool
            /// For a cutout: what part of which file it is.
            let cutout: CutoutSpec?
            let cutoutSummary: String?
            let localPath: String
            let fileExists: Bool
            /// What is wrong with the file when it is there but holds nothing
            /// (empty, an empty archive); absent when it is fine.
            let fileProblem: String?
            let fileSize: Int64?
            let downloadedAtISO: String
            /// The id of the record this one duplicates — kept under a
            /// malformed publisher id, its observation kept already. The
            /// person's to delete.
            let duplicateOf: String?

            init(_ obs: DownloadedObservationOut) {
                id = obs.id
                publisherID = obs.publisherID
                collection = obs.collection
                observationID = obs.observationID
                targetName = obs.targetName
                instrument = obs.instrument
                filter = obs.filter
                calLevel = obs.calLevel
                downloaded = !obs.localPath.isEmpty && obs.fileProblem == nil
                cutout = obs.cutout
                cutoutSummary = obs.cutout?.summary
                localPath = DownloadsFolder.displayPath(obs.localPath)
                fileExists = obs.fileExists
                fileProblem = obs.fileProblem
                fileSize = obs.fileSize
                downloadedAtISO = SharedFormatters.iso8601.string(from: obs.downloadedAt)
                duplicateOf = obs.duplicateOf
            }
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_downloaded_observations",
        description: "List the observations kept in Research — downloaded, or kept without their file (`downloaded: false`; save_observation_to_research, remove_downloaded_file). `fileProblem` says when a kept file is missing, cannot be opened, or holds nothing (empty, an empty archive) — such a record is `downloaded: false` — and download_observation fetches it again into the same record. Optional filter by collection (e.g. 'JWST').",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "collection": { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> [DownloadedObservationOut]

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let all = await snapshot()
        let filtered: [DownloadedObservationOut]
        if let collection = args.collection?.trimmingCharacters(in: .whitespaces),
           !collection.isEmpty {
            filtered = all.filter { $0.collection.caseInsensitiveCompare(collection) == .orderedSame }
        } else {
            filtered = all
        }
        return Output(entries: filtered.map(Output.Entry.init))
    }
}

// MARK: - get_downloaded_observation

/// Single downloaded observation by id.
struct GetDownloadedObservationTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let id: String
    }

    typealias Output = ListDownloadedObservationsTool.Output.Entry

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_downloaded_observation",
        description: "Fetch one Research record by its id (UUID, or a unique prefix of it), its publisher id, or its observation id. A miss that is one digit off an id names the id it most likely means.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": { "id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    /// The record, or why none: `ObservationStore.recordForTool`.
    let lookup: @Sendable (_ id: String) async throws -> DownloadedObservationOut

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        Output(try await lookup(args.id))
    }
}

// MARK: - get_observation_notes

/// User-authored note for one observation (text, rating, tags). Returns
/// an empty note if none exists yet — the agent gets a stable shape.
struct GetObservationNotesTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        let publisher_id: String
    }

    struct Output: Encodable, Sendable {
        let publisherID: String
        let text: String
        let rating: Int
        let tags: [String]
        let createdAtISO: String?
        let modifiedAtISO: String?
        let isEmpty: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_observation_notes",
        description: "User-authored note for an observation (text, rating 0-5, tags). Empty if not yet written.",
        schema: #"""
        {
          "type": "object",
          "required": ["publisher_id"],
          "properties": { "publisher_id": { "type": "string" } },
          "additionalProperties": false
        }
        """#
    )

    let lookup: @Sendable (_ publisherID: String) async -> ObservationNoteOut?

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let n = await lookup(args.publisher_id) {
            return Output(
                publisherID: n.publisherID,
                text: n.text,
                rating: n.rating,
                tags: n.tags,
                createdAtISO: iso.string(from: n.createdAt),
                modifiedAtISO: iso.string(from: n.modifiedAt),
                isEmpty: n.isEmpty
            )
        } else {
            return Output(
                publisherID: args.publisher_id,
                text: "",
                rating: 0,
                tags: [],
                createdAtISO: nil,
                modifiedAtISO: nil,
                isEmpty: true
            )
        }
    }
}

// MARK: - Snapshot DTOs

/// Decoupling DTOs: the tools take these flat records via injected
/// closures, so they don't depend on the app-side model types directly.
struct DownloadedObservationOut: Sendable {
    let id: String
    let publisherID: String
    let collection: String
    let observationID: String
    let targetName: String
    let instrument: String
    let filter: String
    let calLevel: String
    let localPath: String
    let fileExists: Bool
    var fileProblem: String? = nil
    let fileSize: Int64?
    let downloadedAt: Date
    var cutout: CutoutSpec? = nil
    /// The record this one duplicates, when it was kept under a malformed id.
    var duplicateOf: String? = nil
}

struct ObservationNoteOut: Sendable {
    let publisherID: String
    let text: String
    let rating: Int
    let tags: [String]
    let createdAt: Date
    let modifiedAt: Date
    let isEmpty: Bool
}
