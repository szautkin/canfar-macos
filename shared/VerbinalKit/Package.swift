// swift-tools-version:5.9
// SPDX-License-Identifier: MPL-2.0
//
// VerbinalKit — shared core for the Verbinal host app and all Verbinal addons.
// Consumed by:
//   * The host app (com.codebg.Verbinal) via local SPM path dependency.
//   * Every Verbinal addon (e.g. com.codebg.Verbinal.addon.notebook / Verbinal Pi)
//     via the same local path dependency, so addon-versus-host protocol drift
//     cannot happen — everyone builds against the same sources.

import PackageDescription

let package = Package(
    name: "VerbinalKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VerbinalKit",
            targets: ["VerbinalKit"]
        )
    ],
    targets: [
        .target(
            name: "VerbinalKit",
            path: "Sources/VerbinalKit"
        ),
        .testTarget(
            name: "VerbinalKitTests",
            dependencies: ["VerbinalKit"],
            path: "Tests/VerbinalKitTests"
        )
    ]
)
