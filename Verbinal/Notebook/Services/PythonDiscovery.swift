// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Discovers Python installations on the system.
/// Uses Process.run() to probe candidates since App Sandbox blocks FileManager
/// access to paths like /opt/homebrew/bin/.
enum PythonDiscovery {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "PythonDiscovery")
    private static var _cachedPython: String?

    /// Find a real Python 3 executable by actually trying to run each candidate.
    static func findPython3() -> String? {
        if let cached = _cachedPython { return cached }

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
            // /usr/bin/python3 is Xcode shim → calls xcrun → blocked in sandbox
        ]

        for path in candidates {
            if tryPython(path) {
                logger.info("Found working Python at \(path)")
                _cachedPython = path
                return path
            }
        }

        logger.warning("No working Python 3 found")
        return nil
    }

    /// Find jupyter-lab.
    static func findJupyterLab() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/jupyter-lab",
            "/usr/local/bin/jupyter-lab",
            "\(home)/miniconda3/bin/jupyter-lab",
            "\(home)/anaconda3/bin/jupyter-lab",
        ]
        for path in candidates {
            if tryExecutable(path) { return path }
        }
        return nil
    }

    static var isPythonAvailable: Bool { findPython3() != nil }
    static var isJupyterAvailable: Bool { findJupyterLab() != nil }

    static func resetCache() { _cachedPython = nil }

    // MARK: - Private

    /// Try to run a Python binary with `--version`. Returns true if it outputs "Python 3.x".
    /// This works inside App Sandbox because Process.run() is allowed.
    private static func tryPython(_ path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Remove sandbox env so the subprocess isn't restricted
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "APP_SANDBOX_CONTAINER_ID")
        proc.environment = env

        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains("Python 3")
        } catch {
            return false
        }
    }

    /// Try to run an executable with `--version` to check if it exists.
    private static func tryExecutable(_ path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
