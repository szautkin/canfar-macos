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
/// fields let the agent describe it (collection, target name,
/// instrument, filter, etc.) so the strip preview is informative; the
/// record keeps the archive's own details of the plane where it has
/// them (`ResearchRecordDetails`). `file` picks one of the plane's
/// files by name instead of the best pick.
struct DownloadObservationTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    struct Args: Decodable, Sendable {
        let publisher_id: String
        var file: String?
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
        /// One of the observation's files by name; nil for the best pick.
        var file: String? = nil
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

        /// The record as the request describes it, before the archive has its say.
        var described: DownloadedObservation {
            DownloadedObservation(publisherID: publisherID, collection: collection, observationID: observationID,
                                  targetName: targetName, instrument: instrument, filter: filter, ra: ra, dec: dec,
                                  startDate: startDate, calLevel: calLevel, localPath: "",
                                  thumbnailURL: thumbnailURL, previewURL: previewURL)
        }
    }

    /// The payload for one request, or why its publisher ID is refused.
    static func payload(_ args: Args) throws -> Payload {
        guard PublisherID(args.publisher_id) != nil else {
            throw ToolFailureReason.invalidArgument(PublisherID.malformed(args.publisher_id))
        }
        let file = args.file?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Payload(publisherID: args.publisher_id, file: file?.isEmpty == false ? file : nil,
                       collection: args.collection ?? "", observationID: args.observationID ?? "",
                       targetName: args.targetName ?? "", instrument: args.instrument ?? "", filter: args.filter ?? "",
                       ra: args.ra ?? "", dec: args.dec ?? "", startDate: args.startDate ?? "",
                       calLevel: args.calLevel ?? "", thumbnailURL: args.thumbnailURL, previewURL: args.previewURL)
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "download_observation",
        description: "Download a single observation FITS to the user's Downloads folder. `publisher_id` is `ivo://cadc.nrc.ca/COLLECTION?OBSERVATION/PRODUCT` (a malformed one is refused). Uses DataLink #this when available, else the plane's CAOM-2 science file, else `/caom2ops/pkg`; `file` fetches one of the plane's files by name instead — a filename from `get_data_links` (`files[].filename` or `caom2Artifacts[].filename`), e.g. the STIS `_x1d.fits` spectrum rather than the `_flt` image. The record's details (target, instrument, filter, position, calibration level, preview) are the archive's for that plane; the ones you pass fill only what the archive lacks. Requires CADC sign-in for proprietary collections (NEOSSAT, embargoed JWST, …). Synchronous with a 10-min applier deadline. Returns the `downloaded_observation_id` (UUID) — an observation already in Research (kept without its file, or downloaded before) keeps its id — which you pass to `get_fits_header`/`get_fits_wcs`/`open_fits_file`/`upload_to_vospace`/`delete_downloaded_observation`.",
        schema: #"""
        {
          "type": "object",
          "required": ["publisher_id"],
          "properties": {
            "publisher_id":  { "type": "string" },
            "file":          { "type": "string", "description": "One of the plane's files by name, from get_data_links; omit for the best pick." },
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
        let payload = try Self.payload(args)
        let label = [args.targetName, args.instrument, args.filter, payload.file]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        let summary = label.isEmpty
            ? "Download \(args.publisher_id)"
            : "Download \(label) (\(args.publisher_id))"
        return try ProposalPlan.encoding(kind: "download_observation", summary: summary, payload: payload)
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
        description: "Download up to 50 observations as one proposal envelope. Each item takes `download_observation`'s arguments (`publisher_id`, optional `file` and details); a malformed publisher ID refuses the batch. Each item lands under a unique filename (observation id + artifact name) so a shared `pkg.txt` cannot abort the batch. The applier continues after per-item failures and returns `succeeded[]` / `failed[]`. Total in-flight time can exceed the MCP request timeout for large batches — prefer groups of ~10 for big FITS files.",
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
        // The single download's payload for each child; one bad ID refuses the batch.
        let payloads = try args.items.map(DownloadObservationTool.payload)
        return try ProposalPlan.encoding(
            kind: "download_observations_bulk",
            summary: "Download \(payloads.count) observation\(payloads.count == 1 ? "" : "s")",
            payload: Payload(items: payloads)
        )
    }
}

// MARK: - Appliers

/// A downloaded temporary file moved into Downloads, ready to be a
/// Research record's file: its path, its size, and a security-scoped
/// bookmark so a sandboxed relaunch can reopen it. The temporary file is
/// removed when the move fails.
func placeInDownloads(tempURL: URL, suggestedFilename: String,
                      downloadService: DownloadService) async throws -> (localPath: String, size: Int64?, bookmark: Data?) {
    let finalURL: URL
    do {
        finalURL = try DownloadsFolder.move(tempURL, named: suggestedFilename)
    } catch {
        try? await downloadService.deleteFile(at: tempURL)
        throw ProposalApplyError.backendError("move into Downloads failed: \(error.localizedDescription)")
    }
    let bookmark = try? finalURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    return (LocalFolderAccessStore.userFacingPath(for: finalURL), await downloadService.fileSize(at: finalURL), bookmark)
}

private let downloadLogger = Logger(subsystem: "com.codebg.Verbinal.agent", category: "downloads")

/// A record's details from what a request described: the app's own
/// knowledge of the plane and the archive's, first (see
/// `AppState.researchRecord(describing:)`).
typealias ResearchRecordDescriber = @Sendable (_ described: DownloadedObservation) async -> DownloadedObservation

/// Apply a single download proposal: fetch via DownloadService, move
/// into Downloads, register in ObservationStore.
struct DownloadObservationApplier: ProposalApplier, ResultReportingApplier {
    let kind = "download_observation"
    let downloadService: DownloadService
    let observationStore: ObservationStore
    var describe: ResearchRecordDescriber = { ResearchRecordDetails.completing($0, from: nil) }
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(DownloadObservationTool.Payload.self, from: proposal.payload)
        let attribution = AgentAttribution.from(proposal: proposal)
        let id = try await Self.runOne(
            payload,
            attribution: attribution,
            downloadService: downloadService,
            observationStore: observationStore,
            describe: describe
        )
        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: kind))
        }
        let extra = AutoAppliedAck.Extra(id: id.uuidString)
        return (try? JSONEncoder().encode(extra)) ?? Data()
    }

    static func runOne(
        _ payload: DownloadObservationTool.Payload,
        attribution: AgentAttribution?,
        downloadService: DownloadService,
        observationStore: ObservationStore,
        describe: ResearchRecordDescriber
    ) async throws -> UUID {
        // The details are looked up while the file comes down.
        async let details = describe(payload.described)
        let result: (tempURL: URL, suggestedFilename: String)
        do {
            // 10-minute wall-clock deadline. A genuinely large FITS
            // can take longer over slow links, but bounding the
            // worst-case hang (URLSession stuck without a server
            // response) matters more than rare legitimate
            // long-tail completes — the applier always emits a
            // terminal lifecycle event. Same rationale as the
            // VOSpace upload watchdog, per F-2026-05-13-A.
            let publisherID = payload.publisherID, file = payload.file
            result = try await withApplierTimeout(seconds: 600, label: "download_observation") {
                if let file { return try await downloadService.downloadToTemp(publisherID: publisherID, file: file) }
                return try await downloadService.downloadToTemp(publisherID: publisherID)
            }
        } catch let pa as ProposalApplyError {
            throw pa
        } catch {
            throw ProposalApplyError.backendError("download failed: \(error.localizedDescription)")
        }
        let placed = try await placeInDownloads(tempURL: result.tempURL, suggestedFilename: result.suggestedFilename,
                                                downloadService: downloadService)
        var observation = await details
        observation.id = UUID()
        observation.localPath = placed.localPath
        observation.fileSize = placed.size
        observation.bookmarkData = placed.bookmark
        observation.downloadedAt = Date()
        observation.agentAttribution = attribution
        // Into Research's record of the observation when it has one (kept
        // without its file, or downloaded before): the id stays the same.
        let stored = await MainActor.run { observationStore.save(observation) }
        downloadLogger.notice("agent download applied: \(payload.publisherID, privacy: .public)")
        return stored.id
    }
}

/// Apply a bulk download proposal: run each item sequentially. Per-item
/// failures are collected; the batch does not abort on the first error.
struct DownloadObservationsBulkApplier: ProposalApplier, ResultReportingApplier {
    let kind = "download_observations_bulk"
    let downloadService: DownloadService
    let observationStore: ObservationStore
    var describe: ResearchRecordDescriber = { ResearchRecordDetails.completing($0, from: nil) }
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(DownloadObservationsBulkTool.Payload.self, from: proposal.payload)
        let attribution = AgentAttribution.from(proposal: proposal)
        var succeeded: [String] = []
        var failed: [AutoAppliedAck.FailedItem] = []
        for item in payload.items {
            do {
                let id = try await DownloadObservationApplier.runOne(
                    item,
                    attribution: attribution,
                    downloadService: downloadService,
                    observationStore: observationStore,
                    describe: describe
                )
                succeeded.append(id.uuidString)
            } catch {
                failed.append(.init(id: item.publisherID, error: error.localizedDescription))
            }
        }
        await MainActor.run {
            activity.append(.applied(proposal: proposal, kind: kind))
        }
        if succeeded.isEmpty, !failed.isEmpty {
            throw ProposalApplyError.backendError(
                "all \(failed.count) bulk downloads failed: \(failed.map(\.error).joined(separator: "; "))"
            )
        }
        let extra = AutoAppliedAck.Extra(succeeded: succeeded, failed: failed.isEmpty ? nil : failed)
        return (try? JSONEncoder().encode(extra)) ?? Data()
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
        description: "Remove a downloaded observation's metadata, optionally deleting the local file.",
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
        if payload.deleteFile, let url = observation.resolvedReadableURL {
            do {
                try await downloadService.deleteFile(at: url)
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
