// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import WebKit

struct NotebookRootView: View {
    @State private var model = NotebookModel()

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            statusBar
            Divider()

            // Content
            if let url = model.serverURL {
                JupyterWebView(url: url)
            } else if model.isStarting {
                Spacer()
                ProgressView("Starting Jupyter...")
                    .font(.subheadline)
                Spacer()
            } else if !model.isAvailable {
                notInstalledView
            } else {
                startView
            }
        }
        .onDisappear {
            // Don't stop on disappear — keep Jupyter running in background
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRunning ? .green : .secondary)
                .frame(width: 8, height: 8)

            Text(model.isRunning ? "Jupyter Running" : "Jupyter Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            if model.isRunning {
                Button("Restart") { Task { await model.restartServer() } }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Stop") { Task { await model.stopServer() } }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var startView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Notebook")
                .font(.title2)
            Text("Run Jupyter notebooks locally.")
                .foregroundStyle(.secondary)
            Button("Start Jupyter") {
                Task { await model.startServer() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
    }

    private var notInstalledView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Jupyter Not Found")
                .font(.title2)
            Text("Install JupyterLab to use this feature:")
                .foregroundStyle(.secondary)
            Text("pip install jupyterlab")
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - WKWebView Wrapper

#if os(macOS)
struct JupyterWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
#else
struct JupyterWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#endif
