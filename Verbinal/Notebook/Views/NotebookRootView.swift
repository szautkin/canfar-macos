// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct NotebookRootView: View {
    @State private var tabHost = NotebookTabHostModel()

    var body: some View {
        VStack(spacing: 0) {
            if tabHost.tabs.isEmpty {
                welcomePage
            } else {
                // Tab bar
                tabBar
                Divider()
                // Active notebook
                if let model = tabHost.activeTab {
                    NotebookView(model: model)
                }
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(tabHost.tabs.enumerated()), id: \.element.id) { index, tab in
                    HStack(spacing: 4) {
                        Button { tabHost.activeTabIndex = index } label: {
                            Text(tab.tabTitle)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .background(index == tabHost.activeTabIndex ? Color.accentColor.opacity(0.15) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Button { tabHost.closeTab(at: index) } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                }

                Button { tabHost.newTab() } label: {
                    Image(systemName: "plus").font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 28)
        .background(.bar)
    }

    // MARK: - Welcome Page

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Notebook")
                .font(.title2)
            Text("Create or open a Jupyter notebook.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("New Notebook") { tabHost.newTab() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                #if os(macOS)
                Button("Open File") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.title = "Open Notebook"
                    panel.message = "Select .ipynb, .py, or .md"
                    let response = panel.runModal()
                    if response == .OK, let url = panel.url {
                        try? tabHost.openFile(url: url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                #endif
            }

            if !PythonDiscovery.isPythonAvailable {
                VStack(spacing: 4) {
                    Label("Python 3 not found", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("brew install python3")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
    }
}

// MARK: - Single Notebook View

private struct NotebookView: View {
    @Bindable var model: NotebookModel

    var body: some View {
        VStack(spacing: 0) {
            notebookToolbar
            Divider()
            cellListView
        }
    }

    // MARK: - Toolbar

    private var notebookToolbar: some View {
        HStack(spacing: 6) {
            // Kernel indicator
            Circle()
                .fill(kernelColor)
                .frame(width: 8, height: 8)
            Text(kernelLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            // File operations
            #if os(macOS)
            Button { try? model.openWithPicker() } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Open file (Cmd+O)")

            Button { try? model.saveFile() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Save (Cmd+S)")
            .keyboardShortcut("s", modifiers: .command)
            #endif

            Divider().frame(height: 16)

            // Run controls
            Button { Task { await model.runSelectedAndAdvance() } } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Run cell (Shift+Return)")
            .disabled(model.kernelState == .busy)

            Button { Task { await model.runAllCells() } } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .help("Run all cells")
            .disabled(model.kernelState == .busy)

            Divider().frame(height: 16)

            // Cell operations
            Button { model.addCellBelow(type: .code) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add code cell below (B)")

            Button { model.clearAllOutputs() } label: {
                Image(systemName: "eraser")
            }
            .buttonStyle(.borderless)
            .help("Clear all outputs")

            Spacer()

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if model.isDirty {
                Text("Modified")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if model.isKernelRunning {
                Button("Restart") { Task { await model.restartKernel() } }
                    .font(.caption2).buttonStyle(.bordered).controlSize(.mini)
            } else {
                Button("Start") { Task { await model.startKernel() } }
                    .font(.caption2).buttonStyle(.borderedProminent).controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Cell List

    private var cellListView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.cells) { cell in
                    CellView(cell: cell, model: model)
                }
            }
            .padding()
        }
    }

    private var kernelColor: Color {
        switch model.kernelState {
        case .idle: return .green
        case .busy: return .orange
        case .starting: return .yellow
        case .stopped: return .secondary
        case .error: return .red
        }
    }

    private var kernelLabel: String {
        switch model.kernelState {
        case .idle: return "Idle"
        case .busy: return "Busy"
        case .starting: return "Starting..."
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }
}

// MARK: - Cell View

private struct CellView: View {
    @Bindable var cell: NotebookCell
    var model: NotebookModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cell header
            HStack(spacing: 6) {
                Text(cell.executionLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                Picker("", selection: $cell.cellType) {
                    Text("Code").tag(NotebookCell.CellType.code)
                    Text("Md").tag(NotebookCell.CellType.markdown)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)

                Spacer()

                if cell.cellType == .code {
                    Button { Task { await model.runCell(cell) } } label: {
                        Image(systemName: "play.fill").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.kernelState == .busy)
                }

                Button { model.moveCell(cell, direction: -1) } label: {
                    Image(systemName: "chevron.up").font(.caption2)
                }
                .buttonStyle(.borderless)

                Button { model.moveCell(cell, direction: 1) } label: {
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .buttonStyle(.borderless)

                Button {
                    model.selectedCellId = cell.id
                    model.deleteSelectedCell()
                } label: {
                    Image(systemName: "trash").font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            // Source editor
            TextEditor(text: $cell.source)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 36, maxHeight: 300)
                .padding(.horizontal, 8)
                .onChange(of: cell.source) { _, _ in model.isDirty = true }
                .onTapGesture {
                    model.selectedCellId = cell.id
                    model.isEditMode = true
                }

            // Outputs
            if !cell.outputs.isEmpty && !cell.isOutputCollapsed {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cell.outputs) { output in
                        outputView(output)
                    }
                }
                .padding(8)
            } else if cell.isOutputCollapsed && !cell.outputs.isEmpty {
                Button { cell.isOutputCollapsed = false } label: {
                    Text("Output collapsed (\(cell.outputs.count) items)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }

            if cell.isExecuting {
                ProgressView().scaleEffect(0.6).padding(.horizontal, 8).padding(.bottom, 2)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(model.selectedCellId == cell.id ? Color.accentColor.opacity(0.05) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    model.selectedCellId == cell.id
                        ? (model.isEditMode ? Color.green.opacity(0.5) : Color.accentColor.opacity(0.4))
                        : Color.secondary.opacity(0.15),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func outputView(_ output: CellOutput) -> some View {
        switch output.type {
        case .stdout:
            Text(output.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        case .stderr:
            Text(output.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        case .result:
            Text(output.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
                .textSelection(.enabled)
        case .error:
            Text(output.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .image:
            #if os(macOS)
            if let b64 = output.imageBase64,
               let data = Data(base64Encoded: b64),
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
            }
            #endif
        }
    }
}

// MARK: - PythonDiscovery availability

extension PythonDiscovery {
    static var isPythonAvailable: Bool {
        findPython3() != nil
    }
}
