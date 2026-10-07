// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The person's side of `run_code`: the session their assistant's code
/// runs in, every run — who sent it, the code, what came back — Start and
/// Stop, a box to run code themselves, and, until an image is set, what it
/// takes. Before it, an assistant could start a session and run code on
/// someone's account with nothing in the app to show it had.
struct RemoteComputeView: View {
    @Bindable var model: RemoteComputeModel
    @Environment(AppState.self) private var appState
    @State private var confirmStop = false
    @State private var confirmRestart = false

    static let repository = URL(string: "https://github.com/szautkin/verbinal-execution")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            toolbar
            if let message = model.message { banner(message) }
            if let problem = model.snapshot?.problem { notReadyBanner(problem) }
            if let drift = model.snapshot?.drift { driftBanner(drift) }
            if model.isConfigured { main } else { setup }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.refresh() }
        // While on screen, and only while something is changing.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await model.tick()
            }
        }
        .task(id: model.selectedRun?.state) { await model.loadOutput() }
        .uiPresented("Stop the Compute Session?", .confirmation, isPresented: $confirmStop)
        .confirmationDialog("Stop the compute session?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { Task { await model.stop() } }
        } message: {
            Text("Stopping deletes the session and anything running in it. Code sent but not yet run stays in the inbox and runs when the session starts again.")
        }
        .uiPresented("Restart the Compute Session?", .confirmation, isPresented: $confirmRestart)
        .confirmationDialog("Restart the compute session with the new settings?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { Task { await model.restartWithSettings() } }
        } message: {
            Text("The session is stopped — deleting it and anything running in it — and one is started with the settings.")
        }
    }

    // MARK: - Where it stands

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Compute").font(.title2.bold())
                Text("Code your AI assistant runs with run_code, and code you run here, goes to one session on your CANFAR account named verbinal-compute. It uses your cores, has no shell and no inbound network, and writes its results to your storage. To size a pool of workers, read the session's cores from its CPU quota, /sys/fs/cgroup/cpu.max (quota ÷ period) — os.cpu_count() and os.sched_getaffinity() count the whole node's.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 820, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(statusLine)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel(Text(statusLine))
                .pointable("compute.status")
        }
    }

    /// A session that cannot start, said with why, and the way out: stop it.
    private func notReadyBanner(_ problem: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(problem)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Stop") { confirmStop = true }
                .disabled(model.isBusy)
                .pointable("compute.notReady.stop")
        }
        .padding(10)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .pointableArea("compute.notReady", label: problem)
    }

    /// A session that differs from Settings, said, with the way to take them.
    private func driftBanner(_ drift: ComputeDrift) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text(String(localized: "The session differs from Settings: \(drift.differences.joined(separator: "; ")). Code goes to it as it is until it is restarted."))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Restart with New Settings") { confirmRestart = true }
                .disabled(model.isBusy)
                .pointable("compute.restart")
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusLine: String {
        let state = model.state.title
        guard model.state == .running, let config = model.snapshot?.configuration else { return state }
        // What the session has, when the platform says; else what Settings asked.
        let session = model.snapshot?.session
        let cores = session.flatMap { ComputeDrift.cores($0.cpuAllocated) }.map(ComputeDrift.number) ?? "\(config.cores)"
        let ram = session.flatMap { PlatformMemory.gigabytes($0.memoryAllocated) }.map(ComputeDrift.number) ?? "\(config.ram)"
        let size = String(localized: "\(cores) cores · \(ram) GB")
        guard let up = ComputeState.uptime(startedAt: model.snapshot?.session?.startedTime) else { return "\(state) · \(size)" }
        let minutes = Int(up / 60)
        let uptime = minutes < 60
            ? String(localized: "up \(minutes) min")
            : String(localized: "up \(minutes / 60) h \(minutes % 60) min")
        return "\(state) · \(size) · \(uptime)"
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.isConfigured {
                Button("Start Session") { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
                    .pointable("compute.start")
            }
            if model.isConfigured || model.hasSession {
                Button("Stop Session") { confirmStop = true }
                    .disabled(!model.canStop)
                    .pointable("compute.stop")
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .accessibilityLabel(Text("Refresh"))
                .disabled(model.isBusy)
            Button("Settings") { appState.requestSettings(.open, section: .aiCompute) }
                .pointable("compute.settings")
            if model.isConfigured || model.hasSession {
                Button("Open Folder in Storage") { appState.showStorageFolder(RunCodeContract.execDir) }
                    .help("The folder the session reads requests from and writes results to")
                    .pointable("compute.openFolder")
            }
            Link("verbinal-execution on GitHub", destination: Self.repository)
            if model.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private func banner(_ message: RemoteComputeModel.Message) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.kind == .error ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(message.kind == .error ? .orange : .secondary)
            Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if message.kind == .error { CopyErrorButton(message: message.text) }
            Button { model.message = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Dismiss"))
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Not set up

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up remote compute").font(.headline)
            Text("1. Get the watcher image: build verbinal-execution from its repository and push it to your project on images.canfar.net.")
            Text("2. Open Settings ▸ AI Compute and set the image, the cores and RAM it runs with, and a registry login if the image is private.")
            Text("3. Come back here and press Start Session. The session takes a minute or two to come up.")
            Text("With auto-apply on, your assistant's code runs without asking first. Turn auto-apply off in Settings ▸ AI Agent to approve each run.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Settings") { appState.requestSettings(.open, section: .aiCompute) }
                    .buttonStyle(.borderedProminent)
                Link("Open the Repository", destination: Self.repository)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(maxWidth: 820, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Set up: the runs, and running code

    private var main: some View {
        HSplitView {
            runList
                .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $model.tab) {
                    Text("Selected Run").tag(RemoteComputeModel.Tab.run)
                    Text("Run Code").tag(RemoteComputeModel.Tab.code)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                switch model.tab {
                case .run: runDetail
                case .code: snippet
                }
            }
            .padding(.leading, 12)
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Runs").font(.caption).foregroundStyle(.secondary)
            if model.runs.isEmpty {
                Text("Nothing has run yet.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            } else {
                List(selection: Binding(get: { model.selectedRunID }, set: { model.select($0) })) {
                    ForEach(model.runs) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(of: run)).font(.callout.weight(.medium))
                            Text("\(SharedFormatters.userMediumDateShortTime.string(from: run.submittedAt)) · \(Self.firstLine(of: run))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(run.id)
                        .accessibilityElement(children: .combine)
                    }
                }
                .accessibilityLabel(Text("Runs"))
            }
        }
    }

    @ViewBuilder
    private var runDetail: some View {
        if let run = model.selectedRun {
            HStack {
                Text(Self.meta(of: run, truncated: model.output.isTruncated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Code") { PlatformClipboard.copy(run.code) }
                Button("Run Again") { Task { await model.runAgain() } }
                    .disabled(!model.canRun)
            }
            labelled("Code") { Text(run.code) }
            switch model.output {
            case .none, .loading:
                ProgressView().controlSize(.small)
            case .waiting:
                Text("Waiting for the result…").foregroundStyle(.secondary)
            case .unavailable(let why):
                Text(why).foregroundStyle(.secondary).textSelection(.enabled)
            case .text(let stdout, let stderr, _):
                labelled("Output") { Text(stdout.isEmpty ? String(localized: "(none)") : stdout) }
                if !stderr.isEmpty { labelled("Errors") { Text(stderr).foregroundStyle(.orange) } }
            }
        } else {
            Text("Choose a run to see its code and what came back.").foregroundStyle(.secondary)
        }
    }

    private func labelled(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                content()
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(minHeight: 60, maxHeight: 260)
            .background(Color.textFieldBackground, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var snippet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Language", selection: $model.language) {
                    ForEach(RunCodeContract.supportedLanguages, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Stepper(value: $model.timeoutSeconds, in: 1...RunCodeContract.maxTimeoutSeconds, step: 10) {
                    Text("Timeout: \(model.timeoutSeconds) s")
                }
                .fixedSize()
                Spacer()
                Button("Run") { Task { await model.runSnippet() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canRun || model.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointable("compute.run")
            }
            TextEditor(text: $model.code)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .frame(minHeight: 200)
                .textEditorName(String(localized: "Code to run"), pointable: "compute.snippet")
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .pointable("compute.snippet")
            Text("It runs as you, on your session — the same way run_code runs your assistant's code.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Words

    static func title(of run: ComputeRun) -> String {
        let who = run.author == .agent ? String(localized: "Assistant") : String(localized: "You")
        return "\(who) · \(run.language) · \(stateTitle(run.state))"
    }

    static func stateTitle(_ state: String) -> String {
        switch state {
        case ComputeRun.running: return String(localized: "running")
        case "ok": return String(localized: "ok")
        case "error": return String(localized: "error")
        case "timeout": return String(localized: "timed out")
        case ComputeRun.noResult: return String(localized: "no result")
        case ComputeRun.notSent: return String(localized: "not sent")
        default: return state
        }
    }

    static func firstLine(of run: ComputeRun) -> String {
        let line = run.code.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    static func meta(of run: ComputeRun, truncated: Bool) -> String {
        var parts = [stateTitle(run.state)]
        if let code = run.exitCode { parts.append(String(localized: "exit \(code)")) }
        if let ms = run.durationMs { parts.append(String(localized: "\((Double(ms) / 1000).formatted(.number.precision(.fractionLength(0...1)))) s")) }
        if truncated { parts.append(String(localized: "output cut short")) }
        return parts.joined(separator: " · ")
    }
}

extension ComputeState {
    /// As the screen's status says it.
    var title: String {
        switch self {
        case .notSetUp: return String(localized: "Not set up")
        case .stopped: return String(localized: "Stopped")
        case .starting: return String(localized: "Starting")
        case .notReady: return String(localized: "Not ready")
        case .running: return String(localized: "Running")
        case .stopping: return String(localized: "Stopping")
        case .failed: return String(localized: "Failed")
        }
    }
}

private extension RemoteComputeModel.Output {
    var isTruncated: Bool {
        if case .text(_, _, let truncated) = self { return truncated }
        return false
    }
}
