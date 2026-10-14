// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// The Cube Viewer's tools that Verbinal for Windows has too: its recent
/// files, the spectrum panel, the channel profile, the transfer curve and
/// its tabs (moved out of CubeViewerControlTools as that file grew).

// MARK: - Windows cube parity tools

/// A viewer's recently opened files, newest first — what its empty screen offers.
struct ListRecentFilesTool: JSONReadTool {
    typealias Args = EmptyArgs
    struct Entry: Encodable, Sendable { let name: String; let path: String }
    let definition: AIToolDefinition
    let snapshot: @Sendable () async -> [Entry]
    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> [Entry] { await snapshot() }

    static func cubes(_ snapshot: @escaping @Sendable () async -> [Entry]) -> ListRecentFilesTool {
        ListRecentFilesTool(definition: definition("list_recent_cubes", "List recently opened Cube Viewer files, newest first — open one with open_cube."),
                            snapshot: snapshot)
    }

    static func fits(_ snapshot: @escaping @Sendable () async -> [Entry]) -> ListRecentFilesTool {
        ListRecentFilesTool(definition: definition("list_recent_fits", "List recently opened FITS Viewer files, newest first — what its empty screen offers; open one with open_fits_file."),
                            snapshot: snapshot)
    }

    private static func definition(_ name: String, _ description: String) -> AIToolDefinition {
        AIToolDefinition.withStaticSchema(name: name, description: description,
                                          schema: #"{"type":"object","properties":{},"additionalProperties":false}"#)
    }
}

struct ShowCubeSpectrumTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true
    struct Args: Decodable, Sendable { let visible: Bool }
    struct Output: Encodable, Sendable { let visible: Bool }
    let definition = AIToolDefinition.withStaticSchema(
        name: "show_cube_spectrum",
        description: "Show or hide the Cube Viewer spectrum panel. Live-applied.",
        schema: #"{"type":"object","required":["visible"],"properties":{"visible":{"type":"boolean"}},"additionalProperties":false}"#)
    let apply: @Sendable (Bool) async -> String?
    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else { return .failed(.invalidArgument("visible must be a boolean")) }
        if let error = await apply(args.visible) { return .failed(.invalidArgument(error)) }
        return (try? .data(JSONEncoder().encode(Output(visible: args.visible)))) ?? .failed(.backendError("encoding failed"))
    }
}

struct GetCubeChannelProfileTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        var firstChannel: Int?
        var lastChannel: Int?
        var bin: Int?
    }
    struct Output: Encodable, Sendable {
        /// Total channels in the cube (nz), whatever was returned.
        let channelCount: Int
        let firstChannel: Int
        let lastChannel: Int
        let bin: Int
        /// The values' unit: the cube's BUNIT; nil when it has none.
        let unit: String?
        let spectralAxis: ProbeCubeSpectrumTool.Output.SpectralAxis?
        /// Each value's place on the spectral axis — `means[i]` is at `axis[i]`.
        let axis: [Double]?
        /// The mean flux of each bin's channels; null where every channel was blanked.
        let means: [Double?]
        let blankedChannels: [Int]
        let truncated: Bool
    }
    let definition = AIToolDefinition.withStaticSchema(
        name: "get_cube_channel_profile",
        description: "Return the Cube Viewer cube's mean flux per channel — each channel's mean over the whole image — with its unit and each value's place on the spectral axis (`axis`, in `spectralAxis.unit`). `firstChannel`/`lastChannel` (0-based, inclusive) and `bin` work as probe_cube_spectrum's; by default it is binned to at most \(CubeSpectrumSlice.profilePoints) values (`bin` says how many channels each holds) — pass bin: 1 for every channel. Null means a blanked bin.",
        schema: #"""
        {"type":"object","properties":{\#(ProbeCubeSpectrumTool.rangeProperties(binDefault: "enough for at most \(CubeSpectrumSlice.profilePoints) values"))},"additionalProperties":false}
        """#)
    let profile: @Sendable (Args) async throws -> Output
    func handle(_ args: Args, context: AIToolContext) async throws -> Output { try await profile(args) }
}

struct SetCubeTransferTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true
    struct Args: Decodable, Sendable { let opacityCurve: [[Double]]?; let reset: Bool? }
    struct Output: Encodable, Sendable { let applied: Bool }
    let definition = AIToolDefinition.withStaticSchema(
        name: "set_cube_transfer",
        description: "Set the Cube Viewer volume opacity curve, or reset it to the default curve. Live-applied. The curve is the one `set_cube_view` takes.",
        schema: #"{"type":"object","properties":{"opacityCurve":\#(SetCubeViewTool.opacityCurveSchema),"reset":{"type":"boolean"}},"additionalProperties":false}"#)
    let apply: @Sendable (Args) async -> String?
    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else {
            return .failed(.invalidArgument("opacityCurve is [[value, alpha], …], values 0-1 — e.g. [[0,0],[0.3,0.2],[0.7,0.6],[1,1]] — or reset: true"))
        }
        if let error = await apply(args) { return .failed(.invalidArgument(error)) }
        return (try? .data(JSONEncoder().encode(Output(applied: true)))) ?? .failed(.backendError("encoding failed"))
    }
}

struct SwitchCubeTabTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true
    struct Args: Decodable, Sendable { let index: Int }
    struct Output: Encodable, Sendable { let applied: Bool; let index: Int }
    let definition = AIToolDefinition.withStaticSchema(
        name: "switch_cube_tab",
        description: "Activate an open Cube Viewer tab by its 0-based index from list_open_tabs. Live-applied.",
        schema: #"{"type":"object","required":["index"],"properties":{"index":{"type":"integer","minimum":0}},"additionalProperties":false}"#)
    let apply: @Sendable (Int) async -> String?
    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else { return .failed(.invalidArgument("index must be an integer")) }
        if let error = await apply(args.index) { return .failed(.invalidArgument(error)) }
        return (try? .data(JSONEncoder().encode(Output(applied: true, index: args.index)))) ?? .failed(.backendError("encoding failed"))
    }
}
