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

final class KernelErrorTests: XCTestCase {

    func testPythonNotFoundDescription() {
        let error = KernelError.pythonNotFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Python"))
    }

    func testNotRunningDescription() {
        let error = KernelError.notRunning
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("not running"))
    }

    func testTimeoutDescription() {
        let error = KernelError.timeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("timed out"))
    }
}

@MainActor
final class NotebookModelTests: XCTestCase {

    func testInitialState() {
        let model = NotebookModel()
        XCTAssertEqual(model.kernelState, .stopped)
        XCTAssertFalse(model.isKernelRunning)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.cells.count, 1, "Should start with one empty cell")
    }

    func testAddCell() {
        let model = NotebookModel()
        model.addCell()
        XCTAssertEqual(model.cells.count, 2)
    }

    func testDeleteCell() {
        let model = NotebookModel()
        model.addCell()
        XCTAssertEqual(model.cells.count, 2)
        model.deleteCell(model.cells[0])
        XCTAssertEqual(model.cells.count, 1)
    }

    func testDeleteLastCellCreatesNew() {
        let model = NotebookModel()
        let onlyCell = model.cells[0]
        model.deleteCell(onlyCell)
        XCTAssertEqual(model.cells.count, 1, "Deleting last cell should create a new empty one")
    }

    func testCellExecutionLabel() {
        let cell = NotebookCell(cellType: .code)
        XCTAssertEqual(cell.executionLabel, "[ ]")
        cell.isExecuting = true
        XCTAssertEqual(cell.executionLabel, "[*]")
        cell.isExecuting = false
        cell.executionCount = 3
        XCTAssertEqual(cell.executionLabel, "[3]")
    }
}
