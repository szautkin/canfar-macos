// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class PythonDiscoveryTests: XCTestCase {

    func testFindPython3ReturnsPath() {
        // macOS always has /usr/bin/python3
        let path = PythonDiscovery.findPython3()
        XCTAssertNotNil(path, "python3 should be available on macOS")
        if let path {
            XCTAssertTrue(path.contains("python3"), "Path should contain python3, got: \(path)")
        }
    }

    func testFindPython3IsExecutable() {
        guard let path = PythonDiscovery.findPython3() else {
            XCTFail("python3 not found")
            return
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    }
}

final class JupyterErrorTests: XCTestCase {

    func testNotInstalledDescription() {
        let error = JupyterError.notInstalled
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("jupyter-lab"))
    }

    func testAlreadyRunningDescription() {
        let error = JupyterError.alreadyRunning
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("already running"))
    }

    func testStartupFailedDescription() {
        let error = JupyterError.startupFailed("timeout")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("timeout"))
    }
}

@MainActor
final class NotebookModelTests: XCTestCase {

    func testInitialState() {
        let model = NotebookModel()
        XCTAssertNil(model.serverURL)
        XCTAssertFalse(model.isStarting)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.errorMessage)
    }
}
