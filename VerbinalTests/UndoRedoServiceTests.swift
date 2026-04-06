// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class UndoRedoServiceTests: XCTestCase {

    func testCaptureAndUndo() {
        let service = UndoRedoService()
        let cells = [NotebookCell(cellType: .code, source: "x = 1")]
        service.captureState(cells: cells, selectedIndex: 0)

        let newCells = [NotebookCell(cellType: .code, source: "x = 2")]
        let result = service.undo(currentCells: newCells, currentSelectedIndex: 0)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.cells.count, 1)
        XCTAssertEqual(result!.cells[0].source, "x = 1")
    }

    func testRedoAfterUndo() {
        let service = UndoRedoService()
        let cells1 = [NotebookCell(cellType: .code, source: "original")]
        service.captureState(cells: cells1, selectedIndex: 0)

        let cells2 = [NotebookCell(cellType: .code, source: "modified")]
        let undone = service.undo(currentCells: cells2, currentSelectedIndex: 0)
        XCTAssertNotNil(undone)

        let redone = service.redo(currentCells: undone!.cells, currentSelectedIndex: 0)
        XCTAssertNotNil(redone)
        XCTAssertEqual(redone!.cells[0].source, "modified")
    }

    func testNewActionClearsRedoStack() {
        let service = UndoRedoService()
        let cells = [NotebookCell(cellType: .code, source: "a")]
        service.captureState(cells: cells, selectedIndex: 0)

        let cells2 = [NotebookCell(cellType: .code, source: "b")]
        _ = service.undo(currentCells: cells2, currentSelectedIndex: 0)
        XCTAssertTrue(service.canRedo)

        // New action clears redo
        service.captureState(cells: [NotebookCell(cellType: .code, source: "c")], selectedIndex: 0)
        XCTAssertFalse(service.canRedo)
    }

    func testMaxDepth() {
        let service = UndoRedoService()
        for i in 0..<60 {
            service.captureState(cells: [NotebookCell(cellType: .code, source: "v\(i)")], selectedIndex: 0)
        }
        // Should have max 50
        var undoCount = 0
        var current = [NotebookCell(cellType: .code, source: "final")]
        while let result = service.undo(currentCells: current, currentSelectedIndex: 0) {
            current = result.cells
            undoCount += 1
        }
        XCTAssertEqual(undoCount, 50)
    }

    func testCanUndoCanRedo() {
        let service = UndoRedoService()
        XCTAssertFalse(service.canUndo)
        XCTAssertFalse(service.canRedo)

        service.captureState(cells: [NotebookCell()], selectedIndex: 0)
        XCTAssertTrue(service.canUndo)
        XCTAssertFalse(service.canRedo)
    }
}
