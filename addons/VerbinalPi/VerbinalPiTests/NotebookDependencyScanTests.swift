// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalPi

/// Covers the off-actor dependency scan behind `NotebookModel.checkDependencies`.
///
/// `checkDependencies` hands plain value inputs to a detached task, does the
/// blocking `pip list` work inside the extracted `nonisolated` helper
/// `scanMissingPackages` (which captures no `self`), then marshals the result
/// back to the MainActor. These tests drive that helper directly, without a
/// real Python install, by exploiting two deterministic paths:
///   - stdlib-only / no third-party imports → the scanner short-circuits before
///     launching any subprocess and returns an empty set;
///   - third-party imports + an unreachable Python path → the `pip list` launch
///     fails, the "installed" set is empty, and every third-party package reads
///     as missing (with module→pip name mapping applied).
final class NotebookDependencyScanTests: XCTestCase {

    // A path guaranteed not to be a launchable interpreter, forcing
    // DependencyScanner.checkInstalled's `try process.run()` to fail and thus
    // report all third-party packages as missing.
    private let unreachablePython = "/nonexistent/path/to/python3-\(UUID().uuidString)"

    // MARK: - Direct helper tests (nonisolated, off-actor)

    func testScanMissingPackagesReturnsEmptyWhenOnlyStdlibImports() {
        let sources = [
            "import os\nimport sys",
            "from collections import defaultdict\nimport json",
        ]
        // All imports are stdlib → no pip names → guard short-circuits before
        // any subprocess, so the python path is never consulted.
        let missing = NotebookModel.scanMissingPackages(
            sources: sources,
            pythonPath: unreachablePython
        )
        XCTAssertTrue(missing.isEmpty, "stdlib-only imports should yield no missing packages")
    }

    func testScanMissingPackagesReturnsEmptyWhenNoImports() {
        let missing = NotebookModel.scanMissingPackages(
            sources: ["x = 1\nprint(x)", "# a comment only"],
            pythonPath: unreachablePython
        )
        XCTAssertTrue(missing.isEmpty)
    }

    func testScanMissingPackagesReportsThirdPartyWhenPipListUnavailable() {
        let sources = [
            "import numpy as np",
            "from pandas import DataFrame\nimport requests",
        ]
        let missing = NotebookModel.scanMissingPackages(
            sources: sources,
            pythonPath: unreachablePython
        )
        // pip list could not run, so the installed set is empty and every
        // third-party module is reported as missing.
        XCTAssertEqual(Set(missing), ["numpy", "pandas", "requests"])
    }

    func testScanMissingPackagesAppliesPipNameMapping() {
        let sources = ["import cv2\nfrom PIL import Image\nimport yaml"]
        let missing = NotebookModel.scanMissingPackages(
            sources: sources,
            pythonPath: unreachablePython
        )
        // Module names map to their pip package names before the install check.
        XCTAssertEqual(Set(missing), ["opencv-python", "Pillow", "PyYAML"])
    }

    func testScanMissingPackagesIgnoresStdlibAmongThirdParty() {
        let sources = ["import os\nimport numpy\nfrom json import loads\nimport requests"]
        let missing = NotebookModel.scanMissingPackages(
            sources: sources,
            pythonPath: unreachablePython
        )
        XCTAssertEqual(Set(missing), ["numpy", "requests"])
    }

    // MARK: - checkDependencies MainActor state (no-Python path)

    /// When no Python is cached, `checkDependencies` returns immediately without
    /// spawning the detached scan, leaving MainActor state untouched. Uses the
    /// real `reset()` so the test needs no host interpreter and no injection.
    @MainActor
    func testCheckDependenciesIsNoOpWhenPythonUnavailable() async {
        PythonDiscoveryService.shared.reset() // pythonPath == nil
        let model = NotebookModel()
        model.cells = [NotebookCell(cellType: .code, source: "import numpy")]

        model.checkDependencies()
        // Give any (unexpected) detached work a chance to run before asserting.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(model.missingPackages.isEmpty)
        XCTAssertFalse(model.showDependencyAlert)
    }
}
