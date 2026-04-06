// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class DependencyScannerTests: XCTestCase {

    func testExtractSimpleImport() {
        let imports = DependencyScanner.extractImports(from: ["import numpy"])
        XCTAssertTrue(imports.contains("numpy"))
    }

    func testExtractFromImport() {
        let imports = DependencyScanner.extractImports(from: ["from astropy.io import fits"])
        XCTAssertTrue(imports.contains("astropy"))
    }

    func testExtractMultipleImports() {
        let imports = DependencyScanner.extractImports(from: ["import numpy, pandas, matplotlib"])
        XCTAssertTrue(imports.contains("numpy"))
        XCTAssertTrue(imports.contains("pandas"))
        XCTAssertTrue(imports.contains("matplotlib"))
    }

    func testExtractAliasedImport() {
        let imports = DependencyScanner.extractImports(from: ["import numpy as np"])
        XCTAssertTrue(imports.contains("numpy"))
        XCTAssertFalse(imports.contains("np"))
    }

    func testExtractSubmoduleImport() {
        let imports = DependencyScanner.extractImports(from: ["from sklearn.model_selection import train_test_split"])
        XCTAssertTrue(imports.contains("sklearn"))
    }

    func testFilterStdlib() {
        let imports: Set<String> = ["os", "sys", "numpy", "json", "pandas"]
        let thirdParty = DependencyScanner.thirdPartyModules(from: imports)
        XCTAssertTrue(thirdParty.contains("numpy"))
        XCTAssertTrue(thirdParty.contains("pandas"))
        XCTAssertFalse(thirdParty.contains("os"))
        XCTAssertFalse(thirdParty.contains("sys"))
        XCTAssertFalse(thirdParty.contains("json"))
    }

    func testPackageNameMapping() {
        XCTAssertEqual(DependencyScanner.pipPackageName(for: "PIL"), "Pillow")
        XCTAssertEqual(DependencyScanner.pipPackageName(for: "cv2"), "opencv-python")
        XCTAssertEqual(DependencyScanner.pipPackageName(for: "sklearn"), "scikit-learn")
        XCTAssertEqual(DependencyScanner.pipPackageName(for: "numpy"), "numpy") // unmapped → identity
    }

    func testEmptySourceReturnsEmpty() {
        let imports = DependencyScanner.extractImports(from: [])
        XCTAssertTrue(imports.isEmpty)
    }

    func testNonImportLinesIgnored() {
        let imports = DependencyScanner.extractImports(from: [
            "x = 42",
            "print('hello')",
            "# import fake",
        ])
        XCTAssertTrue(imports.isEmpty)
    }

    func testMultipleCellSources() {
        let imports = DependencyScanner.extractImports(from: [
            "import numpy\nprint('cell1')",
            "from pandas import DataFrame\nx = 1",
        ])
        XCTAssertTrue(imports.contains("numpy"))
        XCTAssertTrue(imports.contains("pandas"))
    }
}
