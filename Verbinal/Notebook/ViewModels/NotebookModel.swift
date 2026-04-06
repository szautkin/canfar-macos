// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages the native notebook: kernel lifecycle, cells, and execution.
@Observable
@MainActor
final class NotebookModel {
    let kernelService = KernelService()

    var cells: [NotebookCell] = [NotebookCell(cellType: .code)]
    var kernelState: KernelState = .stopped
    var selectedCellId: UUID?
    var executionCounter = 0
    var errorMessage: String?

    var isPythonAvailable: Bool { PythonDiscovery.findPython3() != nil }
    var isKernelRunning: Bool { kernelState == .idle || kernelState == .busy }

    var selectedCell: NotebookCell? {
        cells.first { $0.id == selectedCellId }
    }

    // MARK: - Kernel Lifecycle

    func startKernel() async {
        kernelState = .starting
        errorMessage = nil
        do {
            try await kernelService.start()
            kernelState = .idle
        } catch {
            kernelState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func stopKernel() async {
        await kernelService.stop()
        kernelState = .stopped
    }

    func restartKernel() async {
        await stopKernel()
        await startKernel()
    }

    // MARK: - Cell Operations

    func addCell(after cell: NotebookCell? = nil, type: NotebookCell.CellType = .code) {
        let newCell = NotebookCell(cellType: type)
        if let cell, let idx = cells.firstIndex(where: { $0.id == cell.id }) {
            cells.insert(newCell, at: idx + 1)
        } else {
            cells.append(newCell)
        }
        selectedCellId = newCell.id
    }

    func deleteCell(_ cell: NotebookCell) {
        cells.removeAll { $0.id == cell.id }
        if cells.isEmpty {
            addCell()
        }
    }

    func moveCell(_ cell: NotebookCell, direction: Int) {
        guard let idx = cells.firstIndex(where: { $0.id == cell.id }) else { return }
        let newIdx = idx + direction
        guard newIdx >= 0, newIdx < cells.count else { return }
        cells.swapAt(idx, newIdx)
    }

    // MARK: - Execution

    func runCell(_ cell: NotebookCell) async {
        if !isKernelRunning {
            await startKernel()
        }
        guard isKernelRunning else { return }

        cell.isExecuting = true
        cell.outputs = []
        executionCounter += 1
        let count = executionCounter
        kernelState = .busy

        do {
            let outputs = try await kernelService.execute(code: cell.source, execCount: count)
            cell.outputs = outputs
            cell.executionCount = count
        } catch {
            cell.outputs = [CellOutput(type: .error, text: error.localizedDescription, imageBase64: nil)]
        }

        cell.isExecuting = false
        kernelState = .idle
    }

    func runSelectedAndAdvance() async {
        guard let cell = selectedCell else { return }
        await runCell(cell)
        // Advance to next cell or create new one
        if let idx = cells.firstIndex(where: { $0.id == cell.id }), idx + 1 < cells.count {
            selectedCellId = cells[idx + 1].id
        } else {
            addCell(after: cell)
        }
    }

    func runAllCells() async {
        for cell in cells where cell.cellType == .code {
            await runCell(cell)
        }
    }
}
