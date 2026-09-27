// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Cutouts for agents: what a file can be cut by (get_cutout_options), and
/// a cutout proposed as a download (download_cutout). Both read the same
/// arguments into the same CutoutSpec and judge it with the same
/// `CutoutSource.check` the editor shows — no second idea of a valid cutout.

/// A cutout as an agent writes it: one region (degrees) and optionally a band (metres).
struct CutoutArgs: Decodable, Sendable {
    var publisherId: String
    /// Which file, as get_cutout_options names it; optional when only one can be cut.
    var artifactId: String?
    var circle: CircleArg?
    var box: BoxArg?
    var polygon: [[Double]]?
    var bandMin: Double?
    var bandMax: Double?
    var cutBy: String?
    /// Which images of a multi-extension file a local cut keeps.
    var extensions: [String]?

    struct CircleArg: Decodable, Sendable { let ra: Double; let dec: Double; let radius: Double }
    struct BoxArg: Decodable, Sendable { let ra: Double; let dec: Double; let width: Double; let height: Double }

    static let schemaProperties = #"""
        "publisherId": { "type": "string", "minLength": 1, "description": "The observation (a search result's publisher_id)." },
        "artifactId": { "type": "string", "description": "Which file, as get_cutout_options names it (e.g. cadc:CFHTSG/….fits). Optional when only one file can be cut." },
        "circle": { "type": "object", "description": "Everything within radius of a point. Degrees.", "properties": { "ra": { "type": "number" }, "dec": { "type": "number" }, "radius": { "type": "number", "exclusiveMinimum": 0 } }, "required": ["ra", "dec", "radius"], "additionalProperties": false },
        "box": { "type": "object", "description": "A rectangle on the sky about a point, width along RA and height along Dec. Degrees.", "properties": { "ra": { "type": "number" }, "dec": { "type": "number" }, "width": { "type": "number", "exclusiveMinimum": 0 }, "height": { "type": "number", "exclusiveMinimum": 0 } }, "required": ["ra", "dec", "width", "height"], "additionalProperties": false },
        "polygon": { "type": "array", "description": "Corners as [ra, dec] pairs in degrees, at least three.", "items": { "type": "array", "items": { "type": "number" }, "minItems": 2, "maxItems": 2 } },
        "bandMin": { "type": "number", "description": "Shortest wavelength to keep, METRES (5e-7 is 500 nm). Only for files that can be cut by wavelength." },
        "bandMax": { "type": "number", "description": "Longest wavelength to keep, metres." },
        "extensions": { "type": "array", "items": { "type": "string" }, "description": "Which images of a multi-extension file to keep, by the names get_cutout_options lists (e.g. \"SCI,1\"); left out, every image the region falls on. Only a local cut can choose." },
        "cutBy": { "type": "string", "enum": ["soda", "local"], "description": "Who cuts it: 'soda' on CADC's side (only the part is downloaded), or 'local' from the observation's file already on this computer (instant, offline; the only way for files CADC will not cut). Left out: local when the file is here and can be cut, else soda." }
    """#

    /// The region asked for; nil when none was. More than one is refused.
    func region() throws -> SkyRegion? {
        let given = [circle != nil, box != nil, polygon != nil].filter { $0 }.count
        guard given <= 1 else { throw ToolFailureReason.invalidArgument("give one region: circle, box OR polygon") }
        if let c = circle { return .circle(ra: c.ra, dec: c.dec, radius: c.radius) }
        if let b = box { return .box(ra: b.ra, dec: b.dec, width: b.width, height: b.height) }
        if let p = polygon {
            guard p.allSatisfy({ $0.count == 2 }) else { throw ToolFailureReason.invalidArgument("polygon corners are [ra, dec] pairs") }
            return .polygon(p.map { SkyPoint(ra: $0[0], dec: $0[1]) })
        }
        return nil
    }

    /// Whether these arguments ask for anything — else the suggestion stands.
    var asksAnything: Bool {
        circle != nil || box != nil || polygon != nil || bandMin != nil || bandMax != nil || !(extensions ?? []).isEmpty
    }

    /// The file meant and the way of cutting it: the file named, or the only
    /// one that can be cut. A choice left to guess is refused with the names.
    func pickSource(_ sources: [any CutoutSource]) throws -> any CutoutSource {
        guard !sources.isEmpty else { throw ToolFailureReason.invalidArgument(CutoutOptionsOutput.noneCanBeCut) }
        let files = Array(Set(sources.map(\.file.artifactID))).sorted()
        let named = (artifactId ?? "").trimmingCharacters(in: .whitespaces)
        var candidates = named.isEmpty ? sources : sources.filter { $0.file.artifactID == named || $0.file.fileName == named }
        guard !candidates.isEmpty else {
            throw ToolFailureReason.invalidArgument("no file '\(named)' can be cut from this observation; the ones that can: \(files.joined(separator: ", "))")
        }
        // The way asked for narrows the choice first.
        if let asked = cutBy {
            guard let method = CutoutMethod(rawValue: asked.lowercased()) else {
                throw ToolFailureReason.invalidArgument("cutBy must be soda or local")
            }
            candidates = candidates.filter { $0.method == method }
            guard !candidates.isEmpty else {
                throw ToolFailureReason.invalidArgument(method == .local
                    ? "this file is not on this computer to cut locally; download_observation fetches it, or cut it with cutBy 'soda'"
                    : "CADC offers no cutout service for this file; cut it with cutBy 'local' once it is downloaded")
            }
        }
        guard Set(candidates.map(\.file.artifactID)).count == 1, let chosen = CutoutSources.preferred(candidates) else {
            throw ToolFailureReason.invalidArgument("this observation has \(files.count) files that can be cut; name one as artifactId: \(files.joined(separator: ", "))")
        }
        if let why = chosen.unavailable {
            throw ToolFailureReason.invalidArgument("this file cannot be cut \(chosen.method == .local ? "locally" : "on CADC's side"): \(why)")
        }
        return chosen
    }

    /// The cutout these arguments ask of `source`.
    func spec(for source: any CutoutSource) throws -> CutoutSpec {
        CutoutSpec(artifactID: source.file.artifactID, region: try region(), bandMin: bandMin, bandMax: bandMax,
                   cutBy: source.method, extensions: extensions ?? [])
    }
}

// MARK: - get_cutout_options

/// What get_cutout_options answers.
struct CutoutOptionsOutput: Encodable, Sendable {
    struct File: Encodable, Sendable {
        let artifactId: String
        let fileName: String
        let cutBy: String
        let unavailable: String?
        let parameters: [String]
        /// The images of a multi-extension file a local cut can choose among.
        let images: [String]
        let footprint: SkyRegion?
        let boundingCircle: SkyRegion?
        let bandMinMetres: Double?
        let bandMaxMetres: Double?
        let wholeFileBytes: Int64?
        let suggested: CutoutSpec
        let suggestedSummary: String
        let suggestedBytes: Int64?
    }

    let publisherId: String
    let files: [File]
    let note: String?
    /// When CADC can cut none of the files, why its answer offered no way to.
    let sodaProblems: [String]?

    static let noneCanBeCut = "none of this observation's files can be cut out: CADC offers no cutout service for them, and none is on this computer; download_observation fetches the whole file, which can then be cut locally"

    /// Each file's options, with the cutout the editor would open on. Pure.
    static func from(publisherId: String, sources: [any CutoutSource], hints: CutoutHints?, problems: [String]) -> CutoutOptionsOutput {
        let files = sources.map { source -> File in
            let f = source.file
            let suggested = source.suggest(hints)
            return File(artifactId: f.artifactID, fileName: f.fileName, cutBy: source.method.rawValue,
                        unavailable: source.unavailable, parameters: f.parameters.sorted(), images: f.images, footprint: f.footprint,
                        boundingCircle: f.boundingCircle, bandMinMetres: f.bandMin, bandMaxMetres: f.bandMax,
                        wholeFileBytes: source.wholeFileBytes, suggested: suggested, suggestedSummary: suggested.summary,
                        suggestedBytes: source.estimatedBytes(suggested))
        }
        return CutoutOptionsOutput(publisherId: publisherId, files: files, note: files.isEmpty ? noneCanBeCut : nil,
                                   sodaProblems: files.isEmpty && !problems.isEmpty ? problems : nil)
    }
}

struct GetCutoutOptionsTool: JSONReadTool {
    struct Args: Decodable, Sendable { let publisherId: String }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_cutout_options",
        description: "What an observation's files can be CUT by, each way: cutBy 'soda' — on CADC's side, only the part downloaded (a few MB of a 1.6 GB MegaPipe tile) — and 'local' — from the observation's file already on this computer: instant, offline, and the only way for files CADC will not cut. For each: the parameters it takes (CIRCLE, POLYGON, BAND …), its footprint and wavelength range in metres, its full size, why it cannot be cut this way when it cannot (unavailable), the images of a multi-extension file a local cut can choose among (images), and the cutout the editor would suggest — from the last search's target and wavelengths when they fall on the file — with its size (estimated for soda, exact for local). When CADC can cut none, sodaProblems says why. Read this before download_cutout.",
        schema: #"""
        {
          "type": "object",
          "required": ["publisherId"],
          "properties": { "publisherId": { "type": "string", "minLength": 1 } },
          "additionalProperties": false
        }
        """#
    )

    let options: @Sendable (String) async -> CutoutOptionsOutput

    func handle(_ args: Args, context: AIToolContext) async throws -> CutoutOptionsOutput {
        let id = args.publisherId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw ToolFailureReason.invalidArgument("publisherId is required") }
        return await options(id)
    }
}

// MARK: - download_cutout

struct DownloadCutoutTool: JSONWriteTool {
    static let verbClass: VerbClass = .semanticWrite

    typealias Args = CutoutArgs

    /// The observation and the cutout, already checked.
    struct Payload: Codable, Sendable, Equatable {
        let publisherId: String
        let spec: CutoutSpec
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "download_cutout",
        description: "Propose making a CUTOUT — part of one of an observation's files — into Research, where it is kept as a cutout of the observation, never as the whole of it: cut on CADC's side (cutBy 'soda') or on this computer from the file already downloaded (cutBy 'local'); left out, locally when that file is here and can be cut, else by CADC. Give one region (circle, box or polygon, degrees), for a cube optionally bandMin/bandMax in metres, and for a local cut of a mosaic optionally the images to keep. It is checked against the file before it is proposed: a region off the file is refused with the reason. Use get_cutout_options first. The file lands in Downloads; returns its downloaded_observation_id.",
        schema: """
        {
          "type": "object",
          "required": ["publisherId"],
          "properties": {
        \(CutoutArgs.schemaProperties)
          },
          "additionalProperties": false
        }
        """
    )

    /// The ways the observation's files can be cut.
    let sources: @Sendable (String) async -> [any CutoutSource]

    func plan(_ args: CutoutArgs, context: AIToolContext) async throws -> ProposalPlan {
        let pid = args.publisherId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pid.isEmpty else { throw ToolFailureReason.invalidArgument("publisherId is required") }
        let source = try args.pickSource(await sources(pid))
        let spec = try args.spec(for: source)
        let check = source.check(spec)
        guard check.isValid else { throw ToolFailureReason.invalidArgument(check.errors.map(\.message).joined(separator: " ")) }
        let size = source.estimatedBytes(spec).map { ", about \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? ""
        let verb = spec.cutBy == .local ? "Cut out locally" : "Download a cutout"
        return try ProposalPlan.encoding(
            kind: "download_cutout",
            summary: "\(verb) of \(pid): \(spec.summary)\(size)",
            payload: Payload(publisherId: pid, spec: spec))
    }
}

struct DownloadCutoutApplier: ResultReportingApplier {
    let kind = "download_cutout"
    /// Makes the cutout and keeps it in Research; returns its record's id.
    let download: @Sendable (DownloadCutoutTool.Payload, AgentAttribution?) async throws -> UUID
    let activity: AgentActivityStore

    func apply(_ proposal: PendingProposal) async throws {
        _ = try await applyReturningResult(proposal)
    }

    func applyReturningResult(_ proposal: PendingProposal) async throws -> Data {
        let payload = try JSONDecoder().decode(DownloadCutoutTool.Payload.self, from: proposal.payload)
        let id: UUID
        do {
            id = try await download(payload, AgentAttribution.from(proposal: proposal))
        } catch let failure as ProposalApplyError {
            throw failure
        } catch {
            throw ProposalApplyError.backendError("cutout failed: \(error.localizedDescription)")
        }
        await MainActor.run { activity.append(.applied(proposal: proposal, kind: kind)) }
        return (try? JSONEncoder().encode(AutoAppliedAck.Extra(id: id.uuidString))) ?? Data()
    }
}

// MARK: - show_cutout_editor

/// What the editor shows after an agent opened it.
struct CutoutEditorShown: Encodable, Sendable {
    let shown: Bool
    let artifactId: String?
    let summary: String?
    let errors: [String]
    let warnings: [String]
    let estimatedBytes: Int64?
    let message: String?
}

struct ShowCutoutEditorTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }
    typealias Args = CutoutArgs

    let definition = AIToolDefinition.withStaticSchema(
        name: "show_cutout_editor",
        description: "Open the cutout editor on the person's screen, on one of an observation's files, with the region you give (circle, box or polygon, degrees; bandMin/bandMax in metres) — or the editor's own suggestion from the last search. The reply says what the editor shows and anything wrong with it. Nothing is downloaded: the person adjusts it and presses Download Cutout, or you follow with download_cutout. Live-applied; no proposal.",
        schema: """
        {
          "type": "object",
          "required": ["publisherId"],
          "properties": {
        \(CutoutArgs.schemaProperties)
          },
          "additionalProperties": false
        }
        """
    )

    let show: @Sendable (CutoutArgs) async throws -> CutoutEditorShown

    func handle(_ args: CutoutArgs, context: AIToolContext) async throws -> CutoutEditorShown {
        guard !args.publisherId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolFailureReason.invalidArgument("publisherId is required")
        }
        return try await show(args)
    }
}
