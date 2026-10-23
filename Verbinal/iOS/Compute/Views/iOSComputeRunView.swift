// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// One run (plan 47 2.3): what was sent, what came back, and Run Again. A
/// run still out is read again until its result is there.
struct iOSComputeRunView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.iOSOpenFile) private var openFile
    @State var run: ComputeRunItem
    var onRanAgain: () -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: ComputeRunText.status(run))
                if let exit = run.exitCode {
                    LabeledContent("Exit code", value: "\(exit)")
                }
                if let ms = run.durationMs {
                    LabeledContent("Took", value: ComputeRunText.duration(ms))
                }
                if let date = run.date {
                    LabeledContent("When", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Sent from", value: run.fromThisDevice
                               ? String(localized: "This device") : String(localized: "Another device or an assistant"))
            }

            if let code = run.code {
                Section {
                    monospaced(code)
                } header: {
                    HStack {
                        Text(run.language?.capitalized ?? String(localized: "Code"))
                        Spacer()
                        Button("Copy") { PlatformClipboard.copy(code) }
                            .font(.caption)
                    }
                }
            }

            if run.isFinished {
                Section("Output") {
                    let out = run.stdout ?? ""
                    if out.isEmpty {
                        Text("Nothing on stdout").foregroundStyle(.secondary)
                    } else {
                        monospaced(out)
                    }
                    if run.truncated {
                        Label("The output was cut short.", systemImage: "scissors").font(.caption)
                    }
                }
                if let err = run.stderr, !err.isEmpty {
                    Section("Errors") { monospaced(err).foregroundStyle(.red) }
                }
                let named = ComputeRunItems.homeFITSPaths(in: run.stdout ?? "", username: appState.username)
                if !named.isEmpty {
                    Section {
                        ForEach(named, id: \.self) { path in
                            Button {
                                openFile(FileRef(place: .storage(path: path), name: (path as NSString).lastPathComponent))
                            } label: {
                                Label(path, systemImage: "doc.viewfinder")
                            }
                        }
                    } header: {
                        Text("Files it names")
                    } footer: {
                        Text("FITS files in your storage that the output names: open one to review it.")
                    }
                }
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(run.isWaiting ? String(localized: "Waiting for the session to run it…")
                                           : String(localized: "Waiting for the result…"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(run.firstLine.isEmpty ? String(localized: "Run") : run.firstLine)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Run Again", systemImage: "arrow.clockwise") { runAgain() }
                    .disabled(run.code == nil || !appState.remoteComputeModel.canRun)
            }
        }
        // A run still out: its result is read every few seconds until it is there.
        .task(id: run.isFinished) {
            guard !run.isFinished else { return }
            while !Task.isCancelled && !run.isFinished {
                try? await Task.sleep(for: .seconds(5))
                guard case .done(let result)? = try? await appState.remoteCompute.fetchOut(run.id) else { continue }
                let listing = ComputeRunItems.Listing(id: run.id, hasResult: true, hasRequest: true,
                                                      isWaiting: false, modified: run.date)
                var finished = ComputeRunItems.item(listing, request: nil, result: result)
                finished.code = run.code
                finished.language = run.language
                finished.timeoutSeconds = run.timeoutSeconds
                finished.fromThisDevice = run.fromThisDevice
                run = finished
            }
        }
    }

    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runAgain() {
        guard let code = run.code else { return }
        let model = appState.remoteComputeModel
        model.setSnippet(code: code, language: run.language ?? RunCodeContract.supportedLanguages[0],
                         timeoutSeconds: run.timeoutSeconds ?? RunCodeContract.defaultTimeoutSeconds)
        Task {
            await model.runSnippet()
            onRanAgain()
        }
    }
}

/// How a run reads in the list and on its page.
enum ComputeRunText {
    static func status(_ run: ComputeRunItem) -> String {
        if run.isWaiting { return String(localized: "Waiting") }
        switch run.status ?? ComputeRun.running {
        case "ok": return String(localized: "Done")
        case "error": return String(localized: "Error")
        case "timeout": return String(localized: "Timed out")
        case ComputeRun.noResult: return String(localized: "No result")
        case ComputeRun.notSent: return String(localized: "Not sent")
        case ComputeRun.running: return String(localized: "Running")
        case let other: return other
        }
    }

    static func duration(_ ms: Int) -> String {
        String(localized: "\((Double(ms) / 1000).formatted(.number.precision(.fractionLength(0...1)))) s")
    }
}
