// swift-tools-version:5.9
// SPDX-License-Identifier: MPL-2.0
//
// VerbinalKit — shared core for the Verbinal host app and all Verbinal addons.
// Consumed by:
//   * The host app (com.codebg.Verbinal) via local SPM path dependency.
//   * Every Verbinal addon (e.g. com.codebg.Verbinal.addon.notebook / Verbinal Pi)
//     via the same local path dependency, so addon-versus-host protocol drift
//     cannot happen — everyone builds against the same sources.
//   * The `canfar-mcp` helper executable, which depends on MCPCore alone (no
//     CADC services, no UI, no Foundation-heavy data layer).

import PackageDescription

let package = Package(
    name: "VerbinalKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "VerbinalKit",
            targets: ["VerbinalKit"]
        ),
        // Wire layer for the MCP server. Decoupled from VerbinalKit so the
        // CLI helper can link a tiny binary with no app dependencies.
        .library(
            name: "MCPCore",
            targets: ["MCPCore"]
        )
    ],
    targets: [
        .target(
            name: "MCPCore",
            path: "Sources/MCPCore"
        ),
        .target(
            name: "VerbinalKit",
            dependencies: ["MCPCore"],
            path: "Sources/VerbinalKit"
        ),
        .testTarget(
            name: "VerbinalKitTests",
            dependencies: ["VerbinalKit"],
            path: "Tests/VerbinalKitTests"
        ),
        .testTarget(
            name: "MCPCoreTests",
            dependencies: ["MCPCore"],
            path: "Tests/MCPCoreTests"
        )
    ]
)
