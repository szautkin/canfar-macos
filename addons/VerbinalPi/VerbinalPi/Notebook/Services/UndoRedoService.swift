// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Captures notebook cell state snapshots for undo/redo.
@Observable
@MainActor
final class UndoRedoService {
    private struct Snapshot {
        let cells: [(type: NotebookCell.CellType, source: String)]
        let selectedIndex: Int
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let maxDepth = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Capture current state before a mutation.
    func captureState(cells: [NotebookCell], selectedIndex: Int) {
        let snapshot = Snapshot(
            cells: cells.map { ($0.cellType, $0.source) },
            selectedIndex: selectedIndex
        )
        undoStack.append(snapshot)
        if undoStack.count > maxDepth {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    /// Restore the previous state. Returns the restored cells and selected index.
    func undo(currentCells: [NotebookCell], currentSelectedIndex: Int) -> (cells: [NotebookCell], selectedIndex: Int)? {
        guard let snapshot = undoStack.popLast() else { return nil }

        // Save current state to redo
        redoStack.append(Snapshot(
            cells: currentCells.map { ($0.cellType, $0.source) },
            selectedIndex: currentSelectedIndex
        ))

        return restoreSnapshot(snapshot)
    }

    /// Redo the last undone action.
    func redo(currentCells: [NotebookCell], currentSelectedIndex: Int) -> (cells: [NotebookCell], selectedIndex: Int)? {
        guard let snapshot = redoStack.popLast() else { return nil }

        undoStack.append(Snapshot(
            cells: currentCells.map { ($0.cellType, $0.source) },
            selectedIndex: currentSelectedIndex
        ))

        return restoreSnapshot(snapshot)
    }

    private func restoreSnapshot(_ snapshot: Snapshot) -> (cells: [NotebookCell], selectedIndex: Int) {
        let cells = snapshot.cells.map { NotebookCell(cellType: $0.type, source: $0.source) }
        let idx = min(snapshot.selectedIndex, max(0, cells.count - 1))
        return (cells: cells, selectedIndex: idx)
    }
}
