// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import AppKit

/// Sheet-style dialog that lets the user configure an export: which modules to
/// include, whether to copy attached files, and where to write the bundle.
///
/// Presented as a sheet over the Research tab (or any other feature hosting exports).
/// On success, reveals the bundle in Finder and (optionally) kicks off a share sheet.
struct ExportDialogView: View {
    struct ModuleSelection: Identifiable {
        let id = UUID()
        let moduleID: String
        let displayName: String
        let itemCountLabel: String
        let module: ExportableModule
        var isEnabled: Bool
    }

    let availableModules: [ModuleSelection]
    let exportService: ExportService
    let onVOSpaceUpload: ((URL) async throws -> String)?
    let canUploadToVOSpace: Bool
    let onComplete: ((URL) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var selections: [ModuleSelection]
    @State private var includeFileCopies = false
    /// This dialog's export — from choosing where to its bundle — and the
    /// bundle's upload to VOSpace (plan 38): under way, done, or why not.
    @State private var run: Phase<URL> = .idle
    @State private var upload: Phase<String> = .idle

    private var isExporting: Bool { run.isWorking }
    private var isUploading: Bool { upload.isWorking }
    private var completedBundleURL: URL? { if case .ready(let url) = run { url } else { nil } }
    private var uploadedRemotePath: String? { if case .ready(let path) = upload { path } else { nil } }
    private var problem: Problem? { upload.problem ?? run.problem }

    init(
        availableModules: [ModuleSelection],
        exportService: ExportService,
        onVOSpaceUpload: ((URL) async throws -> String)? = nil,
        canUploadToVOSpace: Bool = false,
        onComplete: ((URL) -> Void)? = nil
    ) {
        self.availableModules = availableModules
        self.exportService = exportService
        self.onVOSpaceUpload = onVOSpaceUpload
        self.canUploadToVOSpace = canUploadToVOSpace
        self.onComplete = onComplete
        _selections = State(initialValue: availableModules)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480, height: 420)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export Data")
                    .font(.title3.bold())
                Text("Choose what to include in your Claude-friendly export bundle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                moduleSection
                optionsSection
                if let completedBundleURL {
                    completionSection(url: completedBundleURL)
                }
                if let problem {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
    }

    private var moduleSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($selections) { $selection in
                    Toggle(isOn: $selection.isEnabled) {
                        HStack(spacing: 6) {
                            Text(selection.displayName)
                                .font(.callout)
                            Spacer()
                            Text(selection.itemCountLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isExporting)
                }
            }
        } label: {
            Text("Modules")
                .font(.caption.bold())
        }
    }

    private var optionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $includeFileCopies) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include downloaded files")
                            .font(.callout)
                        Text("Copies FITS / notebook files into the bundle. Bundle size will be much larger.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(isExporting)
            }
        } label: {
            Text("Options")
                .font(.caption.bold())
        }
    }

    private func completionSection(url: URL) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.bold())
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let uploadedRemotePath {
                    HStack(spacing: 4) {
                        Image(systemName: "icloud.and.arrow.up.fill")
                            .foregroundStyle(.blue)
                        Text("Uploaded to VOSpace: \(uploadedRemotePath)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.selectFile(
                            url.path,
                            inFileViewerRootedAtPath: url.deletingLastPathComponent().path
                        )
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    Button {
                        copyPath(url)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: url) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }

                    if canUploadToVOSpace, onVOSpaceUpload != nil, uploadedRemotePath == nil {
                        Button {
                            Task { await runVOSpaceUpload(url) }
                        } label: {
                            if isUploading {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                                    Text("Uploading…")
                                }
                            } else {
                                Label("Upload to VOSpace", systemImage: "icloud.and.arrow.up")
                            }
                        }
                        .disabled(isUploading)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack {
            if isExporting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Exporting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(completedBundleURL != nil ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isExporting || isUploading)
            if completedBundleURL == nil {
                Button("Export…") {
                    Task { await runExport() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isExporting || !hasEnabledModule)
                .opens("Choose Export Destination")
            }
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var hasEnabledModule: Bool {
        selections.contains { $0.isEnabled }
    }

    private func runExport() async {
        upload = .idle
        let attempt = run.begin()
        guard let destination = await pickDestination() else {
            run.finish(attempt, with: .failure(CancellationError()))
            return
        }

        let activeModules = selections
            .filter { $0.isEnabled }
            .map(\.module)

        let options = ExportOptions(includeFileCopies: includeFileCopies)

        if let bundleURL = await exportService.exportAll(
            to: destination,
            modules: activeModules,
            options: options
        ) {
            run.finish(attempt, with: .success(bundleURL))
            onComplete?(bundleURL)
        } else {
            run.finish(attempt, with: .failure(exportService.export.problem ?? Problem(.other, String(localized: "Export failed"))))
        }
    }

    private func pickDestination() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Choose Export Destination")
        panel.message = String(localized: "A timestamped folder will be created inside the selected directory.")
        panel.prompt = String(localized: "Export Here")

        let fm = FileManager.default
        if let iCloud = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/Verbinal"),
           fm.fileExists(atPath: iCloud.path) {
            panel.directoryURL = iCloud
        } else {
            panel.directoryURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        }

        return await UIPresentations.shared.runModal(panel, "Choose Export Destination") == .OK ? panel.url : nil
    }

    private func copyPath(_ url: URL) {
        PlatformClipboard.copy(url.path)
    }

    private func runVOSpaceUpload(_ url: URL) async {
        guard let onVOSpaceUpload else { return }
        let attempt = upload.begin()
        do {
            upload.finish(attempt, with: .success(try await onVOSpaceUpload(url)))
        } catch {
            upload.finish(attempt, with: .failure(Problem(.other, String(localized: "VOSpace upload failed: \(error.localizedDescription)"))))
        }
    }
}
#endif
