// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Manages a local jupyter-lab subprocess.
actor JupyterService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Jupyter")

    enum State: Equatable {
        case stopped
        case starting
        case running(url: URL)
        case failed(String)
    }

    private var process: Process?
    private var state: State = .stopped

    func getState() -> State { state }

    /// Start a jupyter-lab server on a random port.
    func start(workingDirectory: URL? = nil) async throws -> URL {
        guard case .stopped = state else {
            if case .running(let url) = state { return url }
            throw JupyterError.alreadyRunning
        }

        guard let jupyterPath = PythonDiscovery.findJupyterLab() else {
            state = .failed("jupyter-lab not found. Install with: pip install jupyterlab")
            throw JupyterError.notInstalled
        }

        state = .starting
        Self.logger.info("Starting jupyter-lab from \(jupyterPath)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: jupyterPath)
        proc.arguments = [
            "--no-browser",
            "--port=0",              // random available port
            "--ServerApp.token=''",  // no token for local access
            "--ServerApp.disable_check_xsrf=True",
        ]

        if let dir = workingDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            proc.currentDirectoryURL = dir
        }

        proc.environment = ProcessInfo.processInfo.environment
        proc.environment?["PYTHONIOENCODING"] = "utf-8"

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }

        process = proc

        // Parse stderr for the URL (jupyter-lab prints to stderr)
        let url = try await parseJupyterURL(from: stderrPipe)
        state = .running(url: url)
        Self.logger.info("Jupyter running at \(url)")

        // Monitor for termination
        Task {
            proc.waitUntilExit()
            Self.logger.info("Jupyter exited with code \(proc.terminationStatus)")
            self.state = .stopped
            self.process = nil
        }

        return url
    }

    /// Stop the jupyter-lab server.
    func stop() {
        process?.terminate()
        process = nil
        state = .stopped
    }

    /// Whether the server is running.
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Private

    private func parseJupyterURL(from pipe: Pipe) async throws -> URL {
        // Jupyter prints the URL to stderr, typically:
        // "http://localhost:8888/lab" or "http://127.0.0.1:PORT/..."
        let handle = pipe.fileHandleForReading

        return try await withCheckedThrowingContinuation { continuation in
            var accumulated = ""
            var resolved = false

            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty else {
                    if !resolved {
                        resolved = true
                        continuation.resume(throwing: JupyterError.startupFailed("Process ended without URL"))
                    }
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else { return }
                accumulated += text

                // Look for http://localhost:PORT or http://127.0.0.1:PORT
                let pattern = #"(https?://(?:localhost|127\.0\.0\.1):\d+/[^\s]*)"#
                if let match = accumulated.range(of: pattern, options: .regularExpression) {
                    let urlString = String(accumulated[match]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: urlString), !resolved {
                        resolved = true
                        handle.readabilityHandler = nil
                        continuation.resume(returning: url)
                    }
                }
            }

            // Timeout after 30 seconds
            Task {
                try? await Task.sleep(for: .seconds(30))
                if !resolved {
                    resolved = true
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: JupyterError.startupFailed("Timeout waiting for Jupyter URL"))
                }
            }
        }
    }
}

enum JupyterError: LocalizedError {
    case notInstalled
    case alreadyRunning
    case startupFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "jupyter-lab not found. Install with: pip install jupyterlab"
        case .alreadyRunning: return "Jupyter is already running"
        case .startupFailed(let msg): return "Jupyter startup failed: \(msg)"
        }
    }
}
