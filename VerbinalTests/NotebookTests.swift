// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class PythonDiscoveryTests: XCTestCase {

    func testFindPython3ReturnsPath() {
        PythonDiscovery.resetCache()
        let path = PythonDiscovery.findPython3()
        // May be nil on CI without Homebrew Python — skip if not found
        if let path {
            XCTAssertTrue(path.contains("python"), "Path should contain python, got: \(path)")
            XCTAssertFalse(path.hasPrefix("/usr/bin/"), "Should NOT return Xcode shim at /usr/bin/python3")
        }
    }

    func testFindPython3IsExecutable() {
        PythonDiscovery.resetCache()
        guard let path = PythonDiscovery.findPython3() else {
            // Skip on CI without real Python
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

    func testAddCellBelow() {
        let model = NotebookModel()
        model.addCellBelow()
        XCTAssertEqual(model.cells.count, 2)
    }

    func testAddCellAbove() {
        let model = NotebookModel()
        model.selectedCellId = model.cells[0].id
        model.addCellAbove()
        XCTAssertEqual(model.cells.count, 2)
        XCTAssertEqual(model.selectedCellId, model.cells[0].id, "New cell should be selected")
    }

    func testDeleteSelectedCell() {
        let model = NotebookModel()
        model.addCellBelow()
        XCTAssertEqual(model.cells.count, 2)
        model.selectedCellId = model.cells[0].id
        model.deleteSelectedCell()
        XCTAssertEqual(model.cells.count, 1)
    }

    func testDeleteLastCellCreatesNew() {
        let model = NotebookModel()
        model.selectedCellId = model.cells[0].id
        model.deleteSelectedCell()
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
