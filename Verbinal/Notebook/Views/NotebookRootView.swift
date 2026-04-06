// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct NotebookRootView: View {
    @Environment(AppState.self) private var appState
    @State private var tabHost = NotebookTabHostModel()
    @State private var showRecovery = false
    @State private var recoverableFiles: [(url: URL, name: String, date: Date)] = []

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
        .onChange(of: appState.pendingNotebookURL) { _, url in
            guard let url else { return }
            appState.pendingNotebookURL = nil
            do {
                _ = url.startAccessingSecurityScopedResource()
                try tabHost.openFile(url: url)
            } catch {
                tabHost.lastError = error.localizedDescription
            }
        }
        .task {
            if tabHost.tabs.isEmpty {
                let files = AutoSaveService.findRecoverableFiles()
                if !files.isEmpty {
                    recoverableFiles = files
                    showRecovery = true
                }
            }
        }
        .sheet(isPresented: $showRecovery) {
            NotebookRecoverySheet(
                isPresented: $showRecovery,
                recoverableFiles: $recoverableFiles,
                tabHost: tabHost
            )
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
                        do {
                            _ = url.startAccessingSecurityScopedResource()
                            try tabHost.openFile(url: url)
                        } catch {
                            tabHost.lastError = "Failed to open: \(error.localizedDescription)"
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                #endif
            }

            if let error = tabHost.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
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

            // Recent notebooks
            if !tabHost.recentNotebooks.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Notebooks")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(tabHost.recentNotebooks.entries.prefix(5)) { entry in
                        Button {
                            let url = URL(fileURLWithPath: entry.path)
                            _ = url.startAccessingSecurityScopedResource()
                            do { try tabHost.openFile(url: url) }
                            catch { tabHost.lastError = error.localizedDescription }
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .font(.caption2)
                                Text(entry.name)
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }

            Spacer()
        }
    }
}

// MARK: - Single Notebook View

private struct NotebookView: View {
    @Bindable var model: NotebookModel
    #if os(macOS)
    @State private var keyMonitor: Any?
    @State private var pendingDeleteTime: Date?
    #endif

    var body: some View {
        VStack(spacing: 0) {
            notebookToolbar
            Divider()
            cellListView
        }
        #if os(macOS)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        #endif
        .alert("Missing Python Packages", isPresented: Bindable(model).showDependencyAlert) {
            Button("Install") { Task { await model.installMissingPackages() } }
            Button("Skip", role: .cancel) { model.missingPackages = [] }
        } message: {
            Text("The following packages are needed:\n\(model.missingPackages.joined(separator: ", "))\n\nInstall them via pip?")
        }
    }

    // MARK: - Keyboard Handler

    #if os(macOS)
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Pass through Cmd/Option combos — system shortcuts
            guard event.modifierFlags.intersection([.command, .option]).isEmpty else { return event }

            // Edit mode: only handle Escape
            if model.isEditMode {
                if event.keyCode == 53 { // Escape
                    model.isEditMode = false
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    return nil
                }
                return event
            }

            // Command mode
            guard model.selectedCellId != nil else { return event }
            let chars = event.charactersIgnoringModifiers ?? ""

            switch chars {
            case "a": model.addCellAbove(); return nil
            case "b": model.addCellBelow(); return nil
            case "y": model.changeCellType(.code); return nil
            case "m": model.changeCellType(.markdown); return nil
            case "c": model.copyCell(); return nil
            case "v": model.pasteCell(); return nil
            case "o": model.toggleOutputCollapse(); return nil
            case "d":
                let now = Date()
                if let prev = pendingDeleteTime, now.timeIntervalSince(prev) < 0.5 {
                    model.deleteSelectedCell()
                    pendingDeleteTime = nil
                } else {
                    pendingDeleteTime = now
                }
                return nil
            case "\r": // Enter → edit mode
                model.isEditMode = true
                return nil
            default:
                break
            }

            // Arrow keys
            if event.keyCode == 126 || chars == "k" { model.selectPreviousCell(); return nil } // Up
            if event.keyCode == 125 || chars == "j" { model.selectNextCell(); return nil } // Down

            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif

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
            Button {
                do { try model.openWithPicker() }
                catch { model.errorMessage = error.localizedDescription }
            } label: {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Open file (Cmd+O)")

            Button {
                do { try model.saveFile() }
                catch { model.errorMessage = error.localizedDescription }
            } label: {
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
        HStack(alignment: .top, spacing: 0) {
            // Left gutter — execution label + run button
            VStack(spacing: 2) {
                Text(cell.executionLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                if cell.cellType == .code {
                    Button { Task { await model.runCell(cell) } } label: {
                        Image(systemName: "play.fill").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.kernelState == .busy)
                } else {
                    Image(systemName: "text.quote")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 44)
            .padding(.top, 6)

            // Right content — source + outputs
            VStack(alignment: .leading, spacing: 0) {
                // Dual-view: edit mode shows editor, command mode shows rendered
                let isThisCellEditing = model.selectedCellId == cell.id && model.isEditMode

                if cell.cellType == .markdown && !isThisCellEditing {
                    // Rendered markdown
                    Group {
                        if let attributed = try? AttributedString(markdown: cell.source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(attributed)
                                .font(.caption)
                                .textSelection(.enabled)
                        } else {
                            Text(cell.source)
                                .font(.caption)
                        }
                    }
                    .frame(minHeight: 30, maxHeight: 300, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                    .onTapGesture {
                        model.selectedCellId = cell.id
                        model.isEditMode = true
                    }
                } else if cell.cellType == .code && !isThisCellEditing {
                    // Syntax-highlighted read-only view (command mode)
                    #if os(macOS)
                    SyntaxHighlightedView(source: cell.source)
                        .frame(minHeight: 30, maxHeight: 300)
                        .onTapGesture {
                            model.selectedCellId = cell.id
                            model.isEditMode = true
                        }
                    #else
                    Text(cell.source)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 30, maxHeight: 300)
                    #endif
                } else {
                    // Editable (edit mode)
                    #if os(macOS)
                    if cell.cellType == .code {
                        PythonTextEditor(text: $cell.source)
                            .frame(minHeight: 36, maxHeight: 300)
                            .onChange(of: cell.source) { _, _ in model.isDirty = true }
                    } else {
                        TextEditor(text: $cell.source)
                            .font(.system(.caption, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 36, maxHeight: 300)
                            .onChange(of: cell.source) { _, _ in model.isDirty = true }
                    }
                    #else
                    TextEditor(text: $cell.source)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 36, maxHeight: 300)
                        .onChange(of: cell.source) { _, _ in model.isDirty = true }
                    #endif
                }

                // Outputs
                if !cell.outputs.isEmpty && !cell.isOutputCollapsed {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cell.outputs) { output in
                            outputView(output)
                        }
                    }
                    .padding(.vertical, 4)
                } else if cell.isOutputCollapsed && !cell.outputs.isEmpty {
                    Button { cell.isOutputCollapsed = false } label: {
                        Text("Output collapsed (\(cell.outputs.count) items)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }

                if cell.isExecuting {
                    ProgressView().scaleEffect(0.6).padding(.bottom, 2)
                }
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
            #if os(macOS)
            Text(AttributedString(AnsiColorParser.parse(output.text)))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            #else
            Text(output.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
            #endif
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
        case .html:
            Text(SimpleHtmlRenderer.render(output.text))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Syntax-highlighted read-only view

#if os(macOS)
private struct SyntaxHighlightedView: View {
    let source: String

    var body: some View {
        let tokens = PythonHighlighter.tokens(in: source)
        let attributed = buildAttributedString(tokens: tokens)
        Text(AttributedString(attributed))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
    }

    private func buildAttributedString(tokens: [PythonToken]) -> NSAttributedString {
        let nsSource = source as NSString
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        for token in tokens {
            guard token.range.location + token.range.length <= nsSource.length else { continue }
            result.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
        }
        return result
    }
}
#endif

// MARK: - PythonDiscovery availability

extension PythonDiscovery {
    static var isPythonAvailable: Bool {
        findPython3() != nil
    }
}
