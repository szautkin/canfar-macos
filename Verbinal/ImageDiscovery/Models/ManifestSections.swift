// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One ecosystem's packages in an image — `python`, `python · <env>`, `r`,
/// `dpkg`, `rpm` or `apk` — sorted by name.
struct ManifestSection: Equatable, Sendable {
    let ecosystem: String
    let packages: [ImageManifest.Package]
}

extension ImageManifest {
    /// The packages by ecosystem in the order a reader wants them: Python
    /// (the system's, then each environment's), R, then the system's
    /// package managers. An ecosystem without packages is left out — five
    /// empty sections around one real one is an answer read twice.
    var sections: [ManifestSection] {
        let python = Dictionary(grouping: pythonPackages, by: \.environment)
        func rank(_ env: String) -> Int { env == PythonPackage.systemEnvironment ? 0 : 1 }
        let environments = python.keys.sorted { (rank($0), $0) < (rank($1), $1) }
        let pythonSections = environments.map { env in
            ManifestSection(ecosystem: env == PythonPackage.systemEnvironment ? "python" : "python · \(env)",
                            packages: python[env, default: []].map { Package(name: $0.name, version: $0.version) })
        }
        let others = [("r", rPackages), ("dpkg", dpkgPackages), ("rpm", rpmPackages), ("apk", apkPackages)]
            .map { ManifestSection(ecosystem: $0.0, packages: $0.1) }
        return (pythonSections + others)
            .filter { !$0.packages.isEmpty }
            .map { ManifestSection(ecosystem: $0.ecosystem, packages: $0.packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
    }
}

extension ImageManifest.PythonPackage {
    static let systemEnvironment = "system"

    /// The environment it is installed in; "system" when the probe named none.
    var environment: String { env.isEmpty ? Self.systemEnvironment : env }
}
