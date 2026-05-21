// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log
import VerbinalKit

// MARK: - download_observation (single)

/// Propose downloading one observation by publisher_id. Optional
/// fields let the agent supply CAOM-2 metadata it already fetched
/// (collection, target name, instrument, filter, etc.) so the strip
/// preview is informative; the applier falls back to defaults when
/// fields are omitted.
struct DownloadObservationTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let publisher_id: String
        var collection: String?
        var observationID: String?
        var targetName: String?
        var instrument: String?
        var filter: String?
        var ra: String?
        var dec: String?
        var startDate: String?
        var calLevel: String?
        var thumbnailURL: String?
        var previewURL: String?
    }

    struct Payload: Codable, Sendable {
        let publisherID: String
        let collection: String
        let observationID: String
        let targetName: String
        let instrument: String
        let filter: String
        let ra: String
        let dec: String
        let startDate: String
        let calLevel: String
        let thumbnailURL: String?
        let previewURL: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "download_observation",
        description: "Download a single observation FITS to the user's Downloads folder. Uses DataLink #this when available; falls back to `/caom2ops/pkg`. Requires CADC sign-in for proprietary collections (NEOSSAT, embargoed JWST, …). Synchronous with a 10-min applier deadline. Returns the new `downloaded_observation_id` (UUID) you pass to `get_fits_header`/`get_fits_wcs`/`open_fits_file`/`upload_to_vospace`/`delete_downloaded_observation`.",
        schema: #"""
        {
          "type": "object",
          "required": ["publisher_id"],
          "properties": {
            "publisher_id":  { "type": "string" },
            "collection":    { "type": "string" },
            "observationID": { "type": "string" },
            "targetName":    { "type": "string" },
            "instrument":    { "type": "string" },
            "filter":        { "type": "string" },
            "ra":            { "type": "string" },
            "dec":           { "type": "string" },
            "startDate":     { "type": "string" },
            "calLevel":      { "type": "string" },
            "thumbnailURL":  { "type": "string" },
            "previewURL":    { "type": "string" }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.publisher_id.isEmpty else {
            throw ToolFailureReason.invalidArgument("publisher_id is empty")
        }
        let label = [args.targetName, args.instrument, args.filter]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        let summary = label.isEmpty
            ? "Download \(args.publisher_id)"
            : "Download \(label) (\(args.publisher_id))"
        return try ProposalPlan.encoding(
            kind: "download_observation",
            summary: summary,
            payload: Payload(
                publisherID: args.publisher_id,
                collection: args.collection ?? "",
                observationID: args.observationID ?? "",
                targetName: args.targetName ?? "",
                instrument: args.instrument ?? "",
                filter: args.filter ?? "",
                ra: args.ra ?? "",
                dec: args.dec ?? "",
                startDate: args.startDate ?? "",
                calLevel: args.calLevel ?? "",
                thumbnailURL: args.thumbnailURL,
                previewURL: args.previewURL
            )
        )
    }
}

// MARK: - download_observations_bulk (one proposal, N children)

/// Propose downloading up to 50 observations in a single user click.
/// Raised from the original 10-file cap (2026-04-29 platform review,
/// F-10): typical SNLS / time-series workflows want full-season cadence
/// per filter, which routinely exceeds 10 files. 50 keeps the disk-cost
/// reasonable per click (~16 GB at ~320 MB/file) while not forcing
/// agents to chunk a single scientific intent into multiple proposals.
struct DownloadObservationsBulkTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite
    static let maxBatchSize = 50

    struct Args: Decodable, Sendable {
        let items: [DownloadObservationTool.Args]
    }

    struct Payload: Codable, Sendable {
        let items: [DownloadObservationTool.Payload]
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "download_observations_bulk",
        description: "Download up to 50 observations as one proposal envelope. The applier downloads each in sequence; first failure aborts the rest. Note: total in-flight time can exceed the MCP request timeout for large batches — prefer staging in groups of ~10 if the items are big FITS files.",
        schema: #"""
        {
          "type": "object",
          "required": ["items"],
          "properties": {
            "items": {
              "type": "array",
              "minItems": 1,
              "maxItems": 50,
              "items": { "type": "object" }
            }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard !args.items.isEmpty else {
            throw ToolFailureReason.invalidArgument("items is empty")
        }
        guard args.items.count <= Self.maxBatchSize else {
            throw ToolFailureReason.invalidArgument(
                "max \(Self.maxBatchSize) items per bulk download (raised from 10 to 50 per platform review F-10)"
            )
        }
        // Reuse the single-download payload encoder for each child.
        let payloads = args.items.map { item in
            DownloadObservationTool.Payload(
                publisherID: item.publisher_id,
                collection: item.collection ?? "",
                observationID: item.observationID ?? "",
                targetName: item.targetName ?? "",
                instrument: item.instrument ?? "",
                filter: item.filter ?? "",
                ra: item.ra ?? "",
                dec: item.dec ?? "",
                startDate: item.startDate ?? "",
                calLevel: item.calLevel ?? "",
                thumbnailURL: item.thumbnailURL,
                previewURL: item.previewURL
            )
        }
        return try ProposalPlan.encoding(
            kind: "download_observations_bulk",
            summary: "Download \(payloads.count) observation\(payloads.count == 1 ? "" : "s")",
            payload: Payload(items: payloads)
        )
    }
}

// MARK: - Appliers

/// Resolves the user's Downloads directory for the running app sandbox.
private func userDownloadsDirectory() -> URL {
    if let url = try? FileManager.default.url(
        for: .downloadsDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
    ) {
        return url
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
}

/// Move a temp file into the user's Downloads, deduplicating against
/// any existing same-named file. Returns the final URL.
private func moveIntoDownloads(tempURL: URL, suggestedFilename: String) throws -> URL {
    let dir = userDownloadsDirectory()
    var target = dir.appendingPathComponent(suggestedFilename)
    let fm = FileManager.default
    if fm.fileExists(atPath: target.path) {
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let unique = ext.isEmpty ? "\(base)-\(stamp)" : "\(base)-\(stamp).\(ext)"
        target = dir.appendingPathComponent(unique)
    }
    try fm.moveItem(at: tempURL, to: target)
    return target
}

private let downloadLogger = Logger(subsystem: "com.codebg.Verbinal.agent", category: "downloads")

/// Apply a single download proposal: fetch via DownloadService, move
/// into Downloads, register in ObservationStore.
struct DownloadObservationApplier: ProposalApplier {
    let kind = "download_observation"
    let downloadService: DownloadService
    let observationStore: ObservationStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DownloadObservationTool.Payload.self, from: proposal.payload)
        let attribution = AgentAttribution.from(proposal: proposal)
        try await Self.runOne(
            payload,
            attribution: attribution,
            downloadService: downloadService,
            observationStore: observationStore
        )
        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }

    static func runOne(
        _ payload: DownloadObservationTool.Payload,
        attribution: AgentAttribution?,
        downloadService: DownloadService,
        observationStore: ObservationStore
    ) async throws {
        let result: (tempURL: URL, suggestedFilename: String)
        do {
            // 10-minute wall-clock deadline. A genuinely large FITS
            // can take longer over slow links, but bounding the
            // worst-case hang (URLSession stuck without a server
            // response) matters more than rare legitimate
            // long-tail completes — the applier always emits a
            // terminal lifecycle event. Same rationale as the
            // VOSpace upload watchdog, per F-2026-05-13-A.
            let publisherID = payload.publisherID
            result = try await withApplierTimeout(seconds: 600, label: "download_observation") {
                try await downloadService.downloadToTemp(publisherID: publisherID)
            }
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("download failed: \(error.localizedDescription)")
        }
        let finalURL: URL
        do {
            finalURL = try moveIntoDownloads(
                tempURL: result.tempURL,
                suggestedFilename: result.suggestedFilename
            )
        } catch {
            // Best-effort cleanup of the temp file.
            try? await downloadService.deleteFile(at: result.tempURL)
            throw ProposalApplyError.backendError("move into Downloads failed: \(error.localizedDescription)")
        }
        let size = await downloadService.fileSize(at: finalURL)
        // Capture a security-scoped bookmark so a sandboxed re-launch
        // can re-open the file later (FITS viewer / get_fits_header).
        let bookmark = (try? finalURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ))
        let observation = DownloadedObservation(
            publisherID: payload.publisherID,
            collection: payload.collection,
            observationID: payload.observationID,
            targetName: payload.targetName,
            instrument: payload.instrument,
            filter: payload.filter,
            ra: payload.ra,
            dec: payload.dec,
            startDate: payload.startDate,
            calLevel: payload.calLevel,
            localPath: finalURL.path,
            fileSize: size,
            thumbnailURL: payload.thumbnailURL,
            previewURL: payload.previewURL,
            bookmarkData: bookmark,
            agentAttribution: attribution
        )
        await MainActor.run {
            observationStore.save(observation)
        }
        downloadLogger.notice("agent download applied: \(payload.publisherID, privacy: .public)")
    }
}

/// Apply a bulk download proposal: run each item sequentially. First
/// failure aborts the remainder.
struct DownloadObservationsBulkApplier: ProposalApplier {
    let kind = "download_observations_bulk"
    let downloadService: DownloadService
    let observationStore: ObservationStore
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DownloadObservationsBulkTool.Payload.self, from: proposal.payload)
        let attribution = AgentAttribution.from(proposal: proposal)
        for item in payload.items {
            try await DownloadObservationApplier.runOne(
                item,
                attribution: attribution,
                downloadService: downloadService,
                observationStore: observationStore
            )
        }
        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}

// MARK: - delete_downloaded_observation (destructive)

struct DeleteDownloadedObservationTool: JSONWriteTool {
    static let verbClass: VerbClass = .destructive

    struct Args: Decodable, Sendable {
        let id: String
        var deleteFile: Bool?
    }

    struct Payload: Codable, Sendable {
        let id: String
        let deleteFile: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "delete_downloaded_observation",
        description: "Remove a downloaded observation's metadata, optionally deleting the local file. Destructive — runs immediately when auto-apply is on; otherwise queues for confirmation in the strip.",
        schema: #"""
        {
          "type": "object",
          "required": ["id"],
          "properties": {
            "id":         { "type": "string" },
            "deleteFile": { "type": "boolean", "default": false }
          },
          "additionalProperties": false
        }
        """#
    )

    func plan(_ args: Args, context: AIToolContext) async throws -> ProposalPlan {
        guard UUID(uuidString: args.id) != nil else {
            throw ToolFailureReason.invalidArgument("id is not a UUID")
        }
        let alsoFile = args.deleteFile ?? false
        let summary = alsoFile
            ? "Delete observation \(args.id) AND its local file"
            : "Delete observation \(args.id) metadata only"
        return try ProposalPlan.encoding(
            kind: "delete_downloaded_observation",
            summary: summary,
            payload: Payload(id: args.id, deleteFile: alsoFile)
        )
    }
}

struct DeleteDownloadedObservationApplier: ProposalApplier {
    let kind = "delete_downloaded_observation"
    let store: ObservationStore
    let downloadService: DownloadService
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        let payload = try JSONDecoder().decode(DeleteDownloadedObservationTool.Payload.self, from: proposal.payload)
        guard let id = UUID(uuidString: payload.id) else {
            throw ProposalApplyError.backendError("invalid id")
        }
        let observation = await MainActor.run { store.observations.first(where: { $0.id == id }) }
        guard let observation else {
            throw ProposalApplyError.backendError("downloaded_observation not found: \(id)")
        }
        if payload.deleteFile, observation.fileExists {
            do {
                try await downloadService.deleteFile(at: observation.localURL)
            } catch {
                throw ProposalApplyError.backendError("file delete failed: \(error.localizedDescription)")
            }
        }
        await MainActor.run {
            store.remove(observation)
            activity.append(.applied(proposal: proposal, kind: kind))
        }
    }
}
