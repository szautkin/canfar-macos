// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// Manages a single notebook: kernel lifecycle, cells, file I/O, execution.
@Observable
@MainActor
final class NotebookModel: Identifiable {
    let id = UUID()
    let kernelService = KernelService()
    let autoSave = AutoSaveService()
    let undoRedo = UndoRedoService()

    var cells: [NotebookCell] = [NotebookCell(cellType: .code)]
    var kernelState: KernelState = .stopped
    var selectedCellId: UUID?
    var executionCounter = 0
    var errorMessage: String?
    var missingPackages: [String] = []
    var showDependencyAlert = false

    // File state
    var filePath: URL?
    var isDirty = false
    var isEditMode = false // false = command mode, true = edit mode

    // Cell clipboard
    var cellClipboard: (source: String, type: NotebookCell.CellType)?

    func startAutoSave() {
        autoSave.start(model: self)
    }

    func stopAutoSave() {
        autoSave.stop()
        autoSave.cleanup(for: self)
    }

    var isPythonAvailable: Bool { PythonDiscovery.findPython3() != nil }
    var isKernelRunning: Bool { kernelState == .idle || kernelState == .busy }

    var fileName: String {
        filePath?.lastPathComponent ?? "Untitled"
    }

    var tabTitle: String {
        isDirty ? "\(fileName)*" : fileName
    }

    var selectedCell: NotebookCell? {
        cells.first { $0.id == selectedCellId }
    }

    // MARK: - File I/O

    func openFile(url: URL) throws {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        let doc: NotebookDocument
        switch ext {
        case "py":
            doc = NotebookParser.fromPythonFile(data)
        case "md":
            doc = NotebookParser.fromMarkdownFile(data)
        default:
            doc = try NotebookParser.parse(data)
        }

        cells = doc.cells.map { cellData in
            let cell = NotebookCell(
                cellType: cellData.cellType == "markdown" ? .markdown : .code,
                source: cellData.sourceText
            )
            cell.executionCount = cellData.executionCount
            cell.isOutputCollapsed = cellData.metadata.collapsed ?? false
            // Convert stored outputs
            if let outputs = cellData.outputs {
                cell.outputs = outputs.compactMap { convertOutput($0) }
            }
            return cell
        }

        if cells.isEmpty { cells = [NotebookCell(cellType: .code)] }
        selectedCellId = cells.first?.id
        filePath = url
        isDirty = false

        // Check for missing Python dependencies
        checkDependencies()
    }

    func saveFile() throws {
        guard let url = filePath else {
            try saveFileAs()
            return
        }
        let data = try serializeToData()
        try data.write(to: url, options: .atomic)
        isDirty = false
    }

    #if os(macOS)
    func saveFileAs() throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filePath?.lastPathComponent ?? "Untitled.ipynb"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = "Save Notebook"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        filePath = url
        let data = try serializeToData()
        try data.write(to: url, options: .atomic)
        isDirty = false
    }

    func openWithPicker() throws {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Notebook"
        panel.message = "Select a .ipynb, .py, or .md file"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        try openFile(url: url)
    }
    #endif

    func newNotebook() {
        let doc = NotebookParser.createEmpty()
        cells = doc.cells.map { NotebookCell(cellType: .code, source: $0.sourceText) }
        if cells.isEmpty { cells = [NotebookCell(cellType: .code)] }
        selectedCellId = cells.first?.id
        filePath = nil
        isDirty = false
        executionCounter = 0
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

    // MARK: - Undo/Redo

    private func captureForUndo() {
        let idx = cells.firstIndex(where: { $0.id == selectedCellId }) ?? 0
        undoRedo.captureState(cells: cells, selectedIndex: idx)
    }

    func undo() {
        let idx = cells.firstIndex(where: { $0.id == selectedCellId }) ?? 0
        guard let restored = undoRedo.undo(currentCells: cells, currentSelectedIndex: idx) else { return }
        cells = restored.cells
        selectedCellId = cells.indices.contains(restored.selectedIndex) ? cells[restored.selectedIndex].id : cells.first?.id
        isDirty = true
    }

    func redo() {
        let idx = cells.firstIndex(where: { $0.id == selectedCellId }) ?? 0
        guard let restored = undoRedo.redo(currentCells: cells, currentSelectedIndex: idx) else { return }
        cells = restored.cells
        selectedCellId = cells.indices.contains(restored.selectedIndex) ? cells[restored.selectedIndex].id : cells.first?.id
        isDirty = true
    }

    // MARK: - Cell Operations

    func addCellAbove(type: NotebookCell.CellType = .code) {
        captureForUndo()
        let newCell = NotebookCell(cellType: type)
        if let sel = selectedCell, let idx = cells.firstIndex(where: { $0.id == sel.id }) {
            cells.insert(newCell, at: idx)
        } else {
            cells.insert(newCell, at: 0)
        }
        selectedCellId = newCell.id
        isDirty = true
    }

    func addCellBelow(type: NotebookCell.CellType = .code) {
        captureForUndo()
        let newCell = NotebookCell(cellType: type)
        if let sel = selectedCell, let idx = cells.firstIndex(where: { $0.id == sel.id }) {
            cells.insert(newCell, at: min(idx + 1, cells.count))
        } else {
            cells.append(newCell)
        }
        selectedCellId = newCell.id
        isDirty = true
    }

    func deleteSelectedCell() {
        captureForUndo()
        guard let sel = selectedCell else { return }
        let idx = cells.firstIndex(where: { $0.id == sel.id }) ?? 0
        cells.removeAll { $0.id == sel.id }
        if cells.isEmpty { cells = [NotebookCell(cellType: .code)] }
        selectedCellId = cells[min(idx, cells.count - 1)].id
        isDirty = true
    }

    func moveCell(_ cell: NotebookCell, direction: Int) {
        guard let idx = cells.firstIndex(where: { $0.id == cell.id }) else { return }
        let newIdx = idx + direction
        guard newIdx >= 0, newIdx < cells.count else { return }
        cells.swapAt(idx, newIdx)
        isDirty = true
    }

    func changeCellType(_ type: NotebookCell.CellType) {
        selectedCell?.cellType = type
        isDirty = true
    }

    func copyCell() {
        guard let cell = selectedCell else { return }
        cellClipboard = (source: cell.source, type: cell.cellType)
    }

    func pasteCell() {
        guard let clip = cellClipboard else { return }
        let newCell = NotebookCell(cellType: clip.type, source: clip.source)
        if let sel = selectedCell, let idx = cells.firstIndex(where: { $0.id == sel.id }) {
            cells.insert(newCell, at: idx + 1)
        } else {
            cells.append(newCell)
        }
        selectedCellId = newCell.id
        isDirty = true
    }

    func toggleOutputCollapse() {
        guard let cell = selectedCell else { return }
        cell.isOutputCollapsed.toggle()
    }

    func selectPreviousCell() {
        guard let sel = selectedCell, let idx = cells.firstIndex(where: { $0.id == sel.id }), idx > 0 else { return }
        selectedCellId = cells[idx - 1].id
        isEditMode = false
    }

    func selectNextCell() {
        guard let sel = selectedCell, let idx = cells.firstIndex(where: { $0.id == sel.id }), idx < cells.count - 1 else { return }
        selectedCellId = cells[idx + 1].id
        isEditMode = false
    }

    func clearAllOutputs() {
        for cell in cells {
            cell.outputs = []
            cell.executionCount = nil
        }
        isDirty = true
    }

    // MARK: - Execution

    func runCell(_ cell: NotebookCell) async {
        if !isKernelRunning { await startKernel() }
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
        isDirty = true
    }

    func runSelectedAndAdvance() async {
        guard let cell = selectedCell else { return }
        await runCell(cell)
        if let idx = cells.firstIndex(where: { $0.id == cell.id }), idx + 1 < cells.count {
            selectedCellId = cells[idx + 1].id
        } else {
            addCellBelow()
        }
    }

    func runAllCells() async {
        for cell in cells where cell.cellType == .code {
            await runCell(cell)
        }
    }

    // MARK: - Dependencies

    func checkDependencies() {
        guard let pythonPath = PythonDiscovery.findPython3() else { return }
        let sources = cells.filter { $0.cellType == .code }.map(\.source)
        Task.detached {
            let missing = DependencyScanner.findMissing(sources: sources, pythonPath: pythonPath)
            await MainActor.run {
                self.missingPackages = missing
                self.showDependencyAlert = !missing.isEmpty
            }
        }
    }

    func installMissingPackages() async {
        guard let pythonPath = PythonDiscovery.findPython3(), !missingPackages.isEmpty else { return }
        let packages = missingPackages.joined(separator: " ")
        // Run via kernel harness %pip install
        if !isKernelRunning { await startKernel() }
        guard isKernelRunning else { return }

        let code = "%pip install \(packages)"
        let outputs = try? await kernelService.execute(code: code, execCount: 0)
        // Show install results in a temporary cell
        if let outputs, !outputs.isEmpty {
            let installCell = NotebookCell(cellType: .code, source: "# Package installation")
            installCell.outputs = outputs
            cells.insert(installCell, at: 0)
        }
        missingPackages = []
    }

    // MARK: - Private

    private func serializeToData() throws -> Data {
        var doc = NotebookDocument(
            metadata: NotebookDocMetadata(kernelspec: KernelSpec(), languageInfo: LanguageInfo()),
            cells: cells.map { cell in
                var cellData = NotebookCellData(
                    cellType: cell.cellType == .markdown ? "markdown" : "code",
                    source: NotebookParser.splitSourceLines(cell.source),
                    id: NotebookParser.generateCellId()
                )
                cellData.executionCount = cell.executionCount
                if cell.cellType == .code {
                    cellData.outputs = [] // outputs not serialized for simplicity
                }
                cellData.metadata = CellMeta(collapsed: cell.isOutputCollapsed ? true : nil)
                return cellData
            }
        )
        return try NotebookParser.serialize(doc)
    }

    private func convertOutput(_ data: CellOutputData) -> CellOutput? {
        switch data.outputType {
        case "stream":
            let name = data.name ?? "stdout"
            return CellOutput(type: name == "stderr" ? .stderr : .stdout, text: data.text?.text ?? "", imageBase64: nil)
        case "execute_result":
            let text = data.data?["text/plain"]?.text ?? ""
            return CellOutput(type: .result, text: text, imageBase64: nil)
        case "display_data":
            if let b64 = data.data?["image/png"]?.text {
                return CellOutput(type: .image, text: "", imageBase64: b64)
            }
            let text = data.data?["text/plain"]?.text ?? ""
            return CellOutput(type: .result, text: text, imageBase64: nil)
        case "error":
            let tb = data.traceback?.joined(separator: "\n") ?? "\(data.ename ?? "Error"): \(data.evalue ?? "")"
            return CellOutput(type: .error, text: tb, imageBase64: nil)
        default:
            return nil
        }
    }
}
