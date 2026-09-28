// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Cube Viewer control tools — read the 3D viewer's state, adjust its
/// render/transfer settings live, and probe a spectrum at a spatial
/// pixel. The setter is `.viewState`: it changes what the user sees on
/// screen, not persistent state, so the router doesn't budget-gate it.

// MARK: - get_cube_view

/// Read the 3D Cube Viewer's full state. All cube-dependent fields are
/// nil when no cube is open (`isOpen == false`).
struct GetCubeViewTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        /// Whether a cube is currently loaded in the Cube Viewer.
        let isOpen: Bool
        let fileName: String?
        /// Cube dimensions: nx × ny spatial pixels, nz spectral channels.
        let nx: Int?
        let ny: Int?
        let nz: Int?
        /// Current channel index, 0-based (0…nz-1).
        let channel: Int?
        /// "slice" (single-channel plane) or "volume" (3D render).
        let viewMode: String?
        let colormap: String?
        let stretch: String?
        /// Transfer-window bounds, normalized 0–1 over the cube's data range.
        let windowLo: Double?
        let windowHi: Double?
        /// Volume-render density multiplier.
        let density: Double?
        let maxIntensityProjection: Bool?
        let autoOrbit: Bool?
        /// Whether channel playback (animation through nz) is running.
        let isPlaying: Bool?
        /// "dark" | "black" | "light".
        let background: String?
        /// Spectral-axis depth exaggeration (0.5–4).
        let spectralScale: Double?
        /// Ray-march step count (96–768). Higher = sharper but slower.
        let quality: Double?
        let showSlicePlane: Bool?
        /// Channel-playback speed (frames per second).
        let playbackFPS: Double?
        /// Opacity transfer-function control points as [value, alpha] pairs, both 0–1.
        let opacityCurve: [[Double]]?
        /// Volume-mode orbit camera pose.
        let camera: Camera?

        struct Camera: Encodable, Sendable {
            let azimuthDeg: Double
            let elevationDeg: Double
            /// 0.5 (closest) … 8 (farthest).
            let distance: Double
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_cube_view",
        description: "Read the 3D Cube Viewer's full state: whether a cube is open, its file name and dimensions (nx, ny spatial pixels; nz channels), the current 0-based channel, view mode (slice|volume), colormap, stretch, transfer window (windowLo/windowHi, normalized 0-1), volume density, max-intensity projection, auto-orbit, channel playback + FPS, background theme, spectral-axis scale, render quality, opacity transfer-function points, and the orbit camera pose (azimuthDeg/elevationDeg/distance). All cube-dependent fields are null when no cube is open.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let snapshot: @Sendable () async -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        await snapshot()
    }
}

// MARK: - set_cube_view

/// Adjust the Cube Viewer's render/transfer settings. Live-applied; no
/// proposal — the user sees the change immediately and can undo by
/// re-adjusting the controls. Every argument is optional; only the
/// fields present are applied.
struct SetCubeViewTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        /// "slice" or "volume".
        let viewMode: String?
        /// 0-based channel index (0…nz-1).
        let channel: Int?
        let colormap: String?
        let stretch: String?
        /// Normalized 0–1 over the cube's data range.
        let windowLo: Double?
        let windowHi: Double?
        /// Volume-render density multiplier (≥ 0).
        let density: Double?
        let maxIntensityProjection: Bool?
        let autoOrbit: Bool?
        /// Start/stop channel playback.
        let playing: Bool?
        /// "dark" | "black" | "light".
        let background: String?
        /// Spectral-axis depth exaggeration (0.5–4).
        let spectralScale: Double?
        /// Ray-march step count (96–768).
        let quality: Double?
        let showSlicePlane: Bool?
        /// Channel-playback speed in frames per second (0.5–60).
        let playbackFPS: Double?
        /// Opacity transfer-function control points: 2–16 [value, alpha]
        /// pairs, both 0–1, non-decreasing in value.
        let opacityCurve: [[Double]]?
        /// "auto" (the load-time first look, the panel's Auto button),
        /// "percentile" (p0.1–p99.9, the panel's 99.9%) or "full" (the data
        /// min–max, Full Range). Applied after windowLo/windowHi, so pass
        /// one or the other.
        let autoWindow: String?
        /// Navigate the user's window to the Cube Viewer so the change is
        /// visible immediately.
        let reveal: Bool?
    }

    /// Pure-shape validation for `opacityCurve`, shared with the wiring
    /// factory and unit-testable without a model. Returns an error message
    /// or nil.
    static func validateOpacityCurve(_ curve: [[Double]]) -> String? {
        guard (2...16).contains(curve.count) else {
            return "opacityCurve needs 2–16 control points (got \(curve.count))"
        }
        var lastValue = -Double.infinity
        for (i, point) in curve.enumerated() {
            guard point.count == 2 else {
                return "opacityCurve point \(i) must be a [value, alpha] pair"
            }
            guard (0...1).contains(point[0]), (0...1).contains(point[1]) else {
                return "opacityCurve point \(i) values must be within 0–1"
            }
            guard point[0] >= lastValue else {
                return "opacityCurve points must be non-decreasing in value (point \(i))"
            }
            lastValue = point[0]
        }
        return nil
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        let message: String?
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_cube_view",
        description: "Adjust the 3D Cube Viewer's settings — every control in its side panel. Live-applied; no proposal. All arguments are optional — pass only the fields to change. `channel` is 0-based (0…nz-1, see get_cube_view). `windowLo`/`windowHi` are normalized 0-1 over the cube's data range (lo < hi). `density` scales volume-render opacity. `opacityCurve` replaces the volume transfer function (2-16 [value, alpha] pairs, 0-1, non-decreasing value). `autoWindow` re-derives the window from the data (\"auto\" = the load-time first look, a little below the background to where the brightest percent begins — the panel's Auto; \"percentile\" = p0.1–p99.9; \"full\" = Full Range). Set `reveal` true to also navigate the user's window to the Cube Viewer so they see the change. Fails if no cube is open or a value is out of range. Use set_cube_camera to rotate/zoom the 3D view.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "viewMode": {
              "type": "string",
              "enum": ["slice", "volume"],
              "description": "Render mode: single-channel slice plane or 3D volume."
            },
            "channel": {
              "type": "integer",
              "minimum": 0,
              "description": "0-based channel index (0…nz-1)."
            },
            "colormap": {
              "type": "string",
              "enum": ["grayscale", "inverted", "heat", "cool", "viridis", "inferno", "magma", "plasma"]
            },
            "stretch": {
              "type": "string",
              "enum": ["linear", "log", "sqrt", "squared", "asinh"]
            },
            "windowLo": {
              "type": "number",
              "minimum": 0,
              "maximum": 1,
              "description": "Lower transfer-window bound, normalized 0-1 over the cube's data range."
            },
            "windowHi": {
              "type": "number",
              "minimum": 0,
              "maximum": 1,
              "description": "Upper transfer-window bound, normalized 0-1 over the cube's data range."
            },
            "density": {
              "type": "number",
              "minimum": 0,
              "description": "Volume-render density multiplier."
            },
            "maxIntensityProjection": {
              "type": "boolean",
              "description": "Use max-intensity projection instead of alpha compositing (volume mode)."
            },
            "autoOrbit": {
              "type": "boolean",
              "description": "Slowly orbit the camera around the volume when idle."
            },
            "playing": {
              "type": "boolean",
              "description": "Start (true) or stop (false) channel playback."
            },
            "background": {
              "type": "string",
              "enum": ["dark", "black", "light"],
              "description": "Viewer background theme."
            },
            "spectralScale": {
              "type": "number",
              "minimum": 0.5,
              "maximum": 4,
              "description": "Spectral-axis depth exaggeration."
            },
            "quality": {
              "type": "number",
              "minimum": 96,
              "maximum": 768,
              "description": "Ray-march step count. Higher = sharper but slower."
            },
            "showSlicePlane": {
              "type": "boolean",
              "description": "Show the current-channel slice-plane marker in the volume."
            },
            "playbackFPS": {
              "type": "number",
              "minimum": 0.5,
              "maximum": 60,
              "description": "Channel-playback speed in frames per second."
            },
            "opacityCurve": {
              "type": "array",
              "minItems": 2,
              "maxItems": 16,
              "items": {
                "type": "array",
                "minItems": 2,
                "maxItems": 2,
                "items": { "type": "number", "minimum": 0, "maximum": 1 }
              },
              "description": "Volume opacity transfer function: [value, alpha] control points, non-decreasing in value."
            },
            "autoWindow": {
              "type": "string",
              "enum": ["auto", "percentile", "full"],
              "description": "Auto-set the transfer window: \"percentile\" = robust p0.1-p99.9 (the panel's Auto button), \"full\" = data min-max (Full Range)."
            },
            "reveal": {
              "type": "boolean",
              "description": "Also navigate the user's window to the Cube Viewer so the change is visible immediately."
            }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Applies the requested changes on the main actor. Returns nil on
    /// success, or a human-readable error message (no cube open, value
    /// out of range, …) that surfaces as `invalidArgument`.
    let apply: @Sendable (Args) async -> String?

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        if let message = await apply(args) {
            return .failed(.invalidArgument(message))
        }
        do {
            let body = Output(applied: true, message: nil)
            let bytes = try JSONEncoder().encode(body)
            return .data(bytes)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}

// MARK: - set_cube_camera

/// Rotate/zoom the 3D volume camera. Absolute pose and relative moves
/// compose (absolute applies first, then the relative deltas). Agent
/// moves are eased over ~0.6 s so the user can follow the rotation —
/// a hard cut would defeat the point of showing them the cube.
struct SetCubeCameraTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true

    struct Args: Decodable, Sendable {
        /// Absolute azimuth in degrees (rotation around the spectral axis).
        let azimuthDeg: Double?
        /// Absolute elevation in degrees (−80…80).
        let elevationDeg: Double?
        /// Absolute camera distance (0.5 closest … 8 farthest).
        let distance: Double?
        /// Relative azimuth rotation in degrees (e.g. 90 = quarter turn).
        let orbitByAzimuthDeg: Double?
        /// Relative elevation change in degrees.
        let orbitByElevationDeg: Double?
        /// Multiplicative zoom: 2 = twice as close, 0.5 = twice as far.
        let zoomFactor: Double?
        /// false = jump instantly instead of the eased move.
        let animated: Bool?
        /// Navigate the user's window to the Cube Viewer first.
        let reveal: Bool?
    }

    struct Pose: Codable, Sendable {
        let azimuthDeg: Double
        let elevationDeg: Double
        let distance: Double
    }

    enum Outcome: Sendable {
        case applied(Pose)
        case rejected(String)
    }

    struct Output: Encodable, Sendable {
        let applied: Bool
        /// The final clamped pose after the move completes.
        let camera: Pose
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "set_cube_camera",
        description: "Rotate and zoom the Cube Viewer's 3D volume camera. Live-applied with a short eased animation so the user can follow the move (set animated=false to jump). Absolute pose (azimuthDeg, elevationDeg -80…80, distance 0.5-8) applies first, then relative moves (orbitByAzimuthDeg/orbitByElevationDeg in degrees, zoomFactor >1 = closer). Switches the viewer to volume mode if needed — the camera only exists there. Set reveal=true to also navigate the user's window to the Cube Viewer. Returns the final clamped pose. Fails if no cube is open.",
        schema: #"""
        {
          "type": "object",
          "properties": {
            "azimuthDeg": {
              "type": "number",
              "description": "Absolute azimuth in degrees (rotation around the spectral axis)."
            },
            "elevationDeg": {
              "type": "number",
              "minimum": -80,
              "maximum": 80,
              "description": "Absolute elevation in degrees."
            },
            "distance": {
              "type": "number",
              "minimum": 0.5,
              "maximum": 8,
              "description": "Absolute camera distance (0.5 closest, 8 farthest)."
            },
            "orbitByAzimuthDeg": {
              "type": "number",
              "description": "Relative azimuth rotation in degrees (90 = quarter turn)."
            },
            "orbitByElevationDeg": {
              "type": "number",
              "description": "Relative elevation change in degrees."
            },
            "zoomFactor": {
              "type": "number",
              "exclusiveMinimum": 0,
              "description": "Multiplicative zoom: 2 = twice as close, 0.5 = twice as far."
            },
            "animated": {
              "type": "boolean",
              "description": "false jumps instantly instead of the ~0.6 s eased move (default true)."
            },
            "reveal": {
              "type": "boolean",
              "description": "Also navigate the user's window to the Cube Viewer."
            }
          },
          "additionalProperties": false
        }
        """#
    )

    let apply: @Sendable (Args) async -> Outcome

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        switch await apply(args) {
        case .rejected(let message):
            return .failed(.invalidArgument(message))
        case .applied(let pose):
            do {
                return .data(try JSONEncoder().encode(Output(applied: true, camera: pose)))
            } catch {
                return .failed(.backendError("\(error)"))
            }
        }
    }
}

// MARK: - probe_cube_spectrum

/// Extract the spectrum (flux vs. channel) at one spatial pixel of the
/// open cube.
struct ProbeCubeSpectrumTool: JSONReadTool {
    struct Args: Decodable, Sendable {
        /// 0-based spatial pixel column (0…nx-1).
        let x: Int
        /// 0-based spatial pixel row (0…ny-1).
        let y: Int
    }

    struct Output: Encodable, Sendable {
        let x: Int
        let y: Int
        /// Total channels in the cube (nz), even when truncated.
        let channelCount: Int
        /// Per-channel values in the cube's native flux units.
        /// Null values are FITS blanked/NaN voxels.
        let spectrum: [Double?]
        /// Channel indices whose source voxel was blanked.
        let blankedChannels: [Int]
        /// True when the spectrum was capped at 8192 values.
        let truncated: Bool
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "probe_cube_spectrum",
        description: "Extract the spectrum at one spatial pixel of the cube open in the Cube Viewer: per-channel values in the cube's native flux units (see the FITS BUNIT header), ordered by channel. (x, y) are 0-based spatial pixel coordinates (0…nx-1, 0…ny-1 from get_cube_view). The spectrum is capped at 8192 values; `truncated` is true when the cube has more channels, and `channelCount` always reports the full nz. Streamed cubes (too large to hold in RAM) cannot be probed — use get_cube_view / get_cube_channel_profile instead; there is no loadFullCube (OOM risk). Fails if no cube is open or the pixel is out of bounds.",
        schema: #"""
        {
          "type": "object",
          "required": ["x", "y"],
          "properties": {
            "x": {
              "type": "integer",
              "minimum": 0,
              "description": "0-based spatial pixel column (0…nx-1)."
            },
            "y": {
              "type": "integer",
              "minimum": 0,
              "description": "0-based spatial pixel row (0…ny-1)."
            }
          },
          "additionalProperties": false
        }
        """#
    )

    /// Reads the spectrum at (x, y). The closure caps the spectrum at
    /// 8192 values and sets `truncated` accordingly. Throws
    /// `ToolFailureReason.targetNotResolved` when no cube is open;
    /// other `ToolFailureReason`s (e.g. `invalidArgument` for an
    /// out-of-bounds pixel) pass through `invoke` typed.
    let probe: @Sendable (Int, Int) async throws -> Output

    func handle(_ args: Args, context: AIToolContext) async throws -> Output {
        try await probe(args.x, args.y)
    }
}

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
    typealias Args = EmptyArgs
    struct Output: Encodable, Sendable {
        let channelCount: Int
        let means: [Double?]
        let spectralAxis: [String?]
    }
    let definition = AIToolDefinition.withStaticSchema(
        name: "get_cube_channel_profile",
        description: "Return mean flux per Cube Viewer channel and formatted spectral-axis values. Null means a blanked channel.",
        schema: #"{"type":"object","properties":{},"additionalProperties":false}"#)
    let profile: @Sendable () async throws -> Output
    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output { try await profile() }
}

struct SetCubeTransferTool: AITool {
    static let verbClass: VerbClass = .viewState
    static let agentSafe: Bool = true
    struct Args: Decodable, Sendable { let opacityCurve: [[Double]]?; let reset: Bool? }
    struct Output: Encodable, Sendable { let applied: Bool }
    let definition = AIToolDefinition.withStaticSchema(
        name: "set_cube_transfer",
        description: "Set the Cube Viewer volume opacity curve, or reset it to the default curve. Live-applied.",
        schema: #"{"type":"object","properties":{"opacityCurve":{"type":"array"},"reset":{"type":"boolean"}},"additionalProperties":false}"#)
    let apply: @Sendable (Args) async -> String?
    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else { return .failed(.invalidArgument("Invalid arguments")) }
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
