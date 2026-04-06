// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct NotebookRootView: View {
    @State private var model = NotebookModel()

    var body: some View {
        VStack(spacing: 0) {
            notebookToolbar
            Divider()

            if !model.isPythonAvailable {
                pythonNotFoundView
            } else {
                cellListView
            }
        }
    }

    // MARK: - Toolbar

    private var notebookToolbar: some View {
        HStack(spacing: 8) {
            // Kernel indicator
            Circle()
                .fill(kernelColor)
                .frame(width: 8, height: 8)
            Text(kernelLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            Button { Task { await model.runSelectedAndAdvance() } } label: {
                Label("Run", systemImage: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: [.shift])
            .disabled(model.kernelState == .busy)
            .help("Run selected cell and advance (Shift+Return)")

            Button { Task { await model.runAllCells() } } label: {
                Label("Run All", systemImage: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.kernelState == .busy)

            Divider().frame(height: 16)

            Button { model.addCell(after: model.selectedCell, type: .code) } label: {
                Label("Code", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Add code cell below")

            Button { model.addCell(after: model.selectedCell, type: .markdown) } label: {
                Label("Markdown", systemImage: "text.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if model.isKernelRunning {
                Button("Restart") { Task { await model.restartKernel() } }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Start Kernel") { Task { await model.startKernel() } }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Cell List

    private var cellListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.cells) { cell in
                    CellView(cell: cell, model: model)
                }
            }
            .padding()
        }
    }

    // MARK: - Python Not Found

    private var pythonNotFoundView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Python 3 Not Found")
                .font(.title2)
            Text("Install Python 3 to use the notebook:")
                .foregroundStyle(.secondary)
            Text("brew install python3")
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Helpers

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
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32)

                Text(cell.cellType == .code ? "Code" : "Markdown")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button { Task { await model.runCell(cell) } } label: {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(cell.cellType != .code || model.kernelState == .busy)

                Button { model.deleteCell(cell) } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Source editor
            TextEditor(text: $cell.source)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 40, maxHeight: 200)
                .padding(.horizontal, 8)
                .onTapGesture { model.selectedCellId = cell.id }

            // Outputs
            if !cell.outputs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cell.outputs) { output in
                        outputView(output)
                    }
                }
                .padding(8)
            }

            if cell.isExecuting {
                ProgressView()
                    .scaleEffect(0.6)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(model.selectedCellId == cell.id ? Color.accentColor.opacity(0.05) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(model.selectedCellId == cell.id ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
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
            if let b64 = output.imageBase64,
               let data = Data(base64Encoded: b64),
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
            }
        }
    }
}
