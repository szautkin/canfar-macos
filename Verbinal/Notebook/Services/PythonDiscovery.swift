// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log

/// Discovers Python installations. Discovery runs in background to avoid blocking UI.
@Observable
@MainActor
final class PythonDiscoveryService {
    static let shared = PythonDiscoveryService()

    private(set) var pythonPath: String?
    private(set) var isSearching = false
    private(set) var didSearch = false

    var isAvailable: Bool { pythonPath != nil }

    /// Trigger async discovery. Safe to call multiple times — only runs once.
    func discoverIfNeeded() {
        guard !didSearch, !isSearching else { return }
        isSearching = true
        Task.detached {
            let path = Self.findPython()
            await MainActor.run {
                self.pythonPath = path
                self.isSearching = false
                self.didSearch = true
                if let path {
                    Self.logger.info("Found Python at \(path)")
                } else {
                    Self.logger.warning("No working Python 3 found")
                }
            }
        }
    }

    func reset() {
        pythonPath = nil
        didSearch = false
    }

    // MARK: - Static sync finder (called from background thread only)

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "PythonDiscovery")

    /// Synchronous Python discovery — MUST be called off main thread.
    nonisolated static func findPython() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/python3.14",
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3",
            "/usr/local/bin/python3.14",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "\(home)/miniconda3/bin/python3",
            "\(home)/anaconda3/bin/python3",
            "\(home)/miniforge3/bin/python3",
            "\(home)/mambaforge/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        ]
        for path in candidates {
            if tryPython(path) { return path }
        }
        return nil
    }

    nonisolated private static func tryPython(_ path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        proc.environment = {
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "APP_SANDBOX_CONTAINER_ID")
            return env
        }()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 { return false }
            let data = (proc.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("Python 3")
        } catch {
            return false
        }
    }
}

// MARK: - Legacy static API (for code that uses PythonDiscovery.findPython3())

enum PythonDiscovery {
    /// Returns cached result or nil. Never blocks. Must be called from MainActor.
    @MainActor static func findPython3() -> String? {
        PythonDiscoveryService.shared.pythonPath
    }
    @MainActor static var isPythonAvailable: Bool {
        PythonDiscoveryService.shared.isAvailable
    }
    @MainActor static func resetCache() {
        PythonDiscoveryService.shared.reset()
    }
}
