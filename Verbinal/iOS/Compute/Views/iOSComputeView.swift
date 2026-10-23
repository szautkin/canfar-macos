// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Compute on iPhone and iPad (plan 47 phase 2): verify on CANFAR, where the
/// data is. The person's compute session — Start, Stop — and every run on
/// it, read back from /arc: theirs from any device, and their assistant's.
struct iOSComputeView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: RemoteComputeModel
    var history: ComputeRunHistory

    @State private var confirmStop = false
    @State private var confirmRestart = false
    @State private var showRunCode = false
    @State private var showSettings = false

    private var runs: [ComputeRunItem] {
        ComputeRunItems.merge(arc: history.arcRuns, local: model.runs)
    }

    var body: some View {
        List {
            statusSection
            bannersSection
            if model.isConfigured || model.hasSession {
                runsSection
            } else {
                setupSection
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refresh() }
        .navigationTitle("Compute")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showRunCode = true
                } label: {
                    Label("Run Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .disabled(!model.canRun)
            }
        }
        .sheet(isPresented: $showRunCode) {
            iOSRunCodeSheet(model: model) { Task { await history.reload() } }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                iOSAIComputeSettingsView(settings: appState.aiComputeSettings, model: model)
            }
            .iosSheetChrome()
        }
        .confirmationDialog("Stop the compute session?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { Task { await model.stop() } }
        } message: {
            Text("Stopping deletes the session and anything running in it. Code sent but not yet run stays in the inbox and runs when the session starts again.")
        }
        .confirmationDialog("Restart the compute session with the new settings?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { Task { await model.restartWithSettings() } }
        } message: {
            Text("The session is stopped — deleting it and anything running in it — and one is started with the settings.")
        }
        .task { await refresh() }
        // While on screen, and only while something is changing.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await model.tick()
            }
        }
        // A run this device sent has finished: /arc has its result now.
        .onChange(of: model.runs.filter(\.isFinished).count) { _, _ in
            Task { await history.reload() }
        }
    }

    private func refresh() async {
        await model.refresh(quiet: true)
        await history.reload()
    }

    // MARK: - The session

    private var statusSection: some View {
        Section {
            HStack {
                Label(model.state.title, systemImage: "terminal")
                    .font(.headline)
                Spacer()
                if model.change.isWorking { ProgressView() }
            }
            if let session = model.snapshot?.session {
                LabeledContent("Size", value: sizeLine(session))
                LabeledContent("Image", value: SessionDisplay.shortImageLabel(session.containerImage))
            }
            HStack(spacing: 10) {
                Button("Start Session") { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
                Button("Stop Session", role: .destructive) { confirmStop = true }
                    .buttonStyle(.bordered)
                    .disabled(!model.canStop)
            }
        } footer: {
            Text("Code you run here, and code your AI assistant runs on the Mac, goes to one session on your CANFAR account named verbinal-compute. It writes its results to your storage.")
        }
    }

    @ViewBuilder
    private var bannersSection: some View {
        if let problem = model.change.problem {
            banner(problem.message, systemImage: "exclamationmark.triangle.fill", color: .red) {
                Button("Dismiss") { model.dismissProblem() }
            }
        }
        if let message = model.message {
            banner(message.text, systemImage: message.kind == .error ? "exclamationmark.triangle.fill" : "info.circle",
                   color: message.kind == .error ? .red : message.kind == .warning ? .orange : .accentColor) {
                Button("Dismiss") { model.message = nil }
            }
        }
        if let problem = model.snapshot?.problem {
            banner(problem, systemImage: "exclamationmark.triangle.fill", color: .red) {
                Button("Stop", role: .destructive) { confirmStop = true }
                    .disabled(model.change.isWorking)
            }
        }
        if let drift = model.snapshot?.drift {
            banner(String(localized: "The session differs from Settings: \(drift.differences.joined(separator: "; ")). Code goes to it as it is until it is restarted."),
                   systemImage: "exclamationmark.arrow.triangle.2.circlepath", color: .orange) {
                Button("Restart with New Settings") { confirmRestart = true }
                    .disabled(model.change.isWorking)
            }
        }
    }

    private func banner(_ text: String, systemImage: String, color: Color,
                        @ViewBuilder action: () -> some View) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(text, systemImage: systemImage)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                action()
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func sizeLine(_ session: Session) -> String {
        [session.coresGiven.isEmpty ? nil : String(localized: "\(session.coresGiven) cores"),
         session.ramGiven.isEmpty ? nil : String(localized: "\(session.ramGiven) RAM")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Runs

    private var runsSection: some View {
        Section {
            if runs.isEmpty {
                if history.load.isWorking {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let problem = history.load.problem {
                    Label(problem.message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("Try Again") { Task { await history.reload() } }
                } else {
                    Text("Nothing has run yet.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(runs) { run in
                    NavigationLink {
                        iOSComputeRunView(run: run) { Task { await history.reload() } }
                    } label: {
                        runRow(run)
                    }
                }
            }
        } header: {
            Text("Runs")
        } footer: {
            Text("The newest \(ComputeRunHistory.limit), from your storage.")
        }
    }

    private func runRow(_ run: ComputeRunItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: run.isFinished ? (run.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill") : "clock")
                    .foregroundStyle(run.isFinished ? (run.isFailure ? .red : .green) : .orange)
                Text(run.firstLine.isEmpty ? String(localized: "(no code)") : run.firstLine)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(verbatim: ComputeRunText.status(run))
                if let language = run.language { Text(verbatim: "· \(language)") }
                if let date = run.date { Text(verbatim: "· \(date.formatted(date: .abbreviated, time: .shortened))") }
                if run.fromThisDevice { Text("· this device") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section("Set up remote compute") {
            Text("1. Get the watcher image: build verbinal-execution from its repository and push it to your project on images.canfar.net.")
            Text("2. Set the image, its cores and RAM, and a registry login if the image is private.")
            Button("AI Compute Settings") { showSettings = true }
            Link("Open the Repository", destination: URL(string: "https://github.com/szautkin/verbinal-execution")!)
        }
    }
}

/// The compute session's settings on iPhone and iPad (plan 47 2.5): the same
/// settings as the Mac's Settings ▸ AI Compute, kept on this device.
struct iOSAIComputeSettingsView: View {
    var settings: AIComputeSettingsService
    var model: RemoteComputeModel

    @Environment(\.dismiss) private var dismiss
    @State private var image = ""
    @State private var cores = 1
    @State private var ram = 1
    @State private var registryUser = ""
    @State private var secret = ""
    @State private var problem: String?

    /// The image of the compute session running now, when settings have none.
    private var runningImage: String? {
        guard settings.settings.image.isEmpty, let session = model.snapshot?.session else { return nil }
        return session.containerImage
    }

    var body: some View {
        Form {
            Section {
                TextField("images.canfar.net/project/verbinal-execution:tag", text: $image)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.callout, design: .monospaced))
                if let runningImage, image.isEmpty {
                    Button("Use the Running Session's Image") { image = runningImage }
                }
                Button("Save") { settings.setImage(image) }
                    .disabled(image == settings.settings.image)
            } header: {
                Text("Image")
            } footer: {
                Text("An image with the verbinal-execution watcher.")
            }

            Section("Size") {
                Stepper("Cores: \(cores)", value: $cores, in: 1...RunCodeContract.maxCores)
                    .onChange(of: cores) { _, value in settings.setCores(value) }
                Stepper("RAM: \(ram) GB", value: $ram, in: 1...RunCodeContract.maxRam)
                    .onChange(of: ram) { _, value in settings.setRam(value) }
            }

            Section {
                TextField("Username", text: $registryUser)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { settings.setUsername(registryUser) }
                SecureField(settings.settings.hasSecret ? String(localized: "Secret saved") : String(localized: "Secret"),
                            text: $secret)
                Button("Save Secret") {
                    settings.setUsername(registryUser)
                    do {
                        try settings.setSecret(secret)
                        secret = ""
                        problem = nil
                    } catch {
                        problem = error.localizedDescription
                    }
                }
                .disabled(secret.isEmpty)
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Registry login (private images)")
            }
        }
        .navigationTitle("AI Compute")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            image = settings.settings.image
            cores = settings.settings.cores
            ram = settings.settings.ram
            registryUser = settings.settings.username
        }
    }
}
