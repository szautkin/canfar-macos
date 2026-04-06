// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Discovers Python installations on the system.
/// Avoids /usr/bin/python3 which is an Xcode shim that fails in App Sandbox.
enum PythonDiscovery {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "PythonDiscovery")

    /// Cached result to avoid re-scanning on every access.
    private static var _cachedPython: String?

    /// Find a real Python 3 executable (not the Xcode shim).
    static func findPython3() -> String? {
        if let cached = _cachedPython { return cached }

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Priority order: Homebrew → conda → pyenv → system (non-shim)
        let candidates = [
            // Homebrew (Apple Silicon)
            "/opt/homebrew/bin/python3",
            "/opt/homebrew/bin/python3.14",
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            // Homebrew (Intel)
            "/usr/local/bin/python3",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            // Conda
            "\(home)/miniconda3/bin/python3",
            "\(home)/anaconda3/bin/python3",
            "\(home)/miniforge3/bin/python3",
            "\(home)/mambaforge/bin/python3",
            "\(home)/.conda/bin/python3",
            // pyenv
            "\(home)/.pyenv/shims/python3",
            // Python.org installer
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            // DO NOT include /usr/bin/python3 — it's an Xcode shim that calls xcrun,
            // which is blocked by App Sandbox ("xcrun: error: cannot be used within an App Sandbox")
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                // Verify it's a real Python, not a shim
                if isRealPython(path) {
                    logger.info("Found Python at \(path)")
                    _cachedPython = path
                    return path
                }
            }
        }

        logger.warning("No real Python 3 found (Xcode shim excluded)")
        return nil
    }

    /// Find the jupyter-lab executable path.
    static func findJupyterLab() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/jupyter-lab",
            "/usr/local/bin/jupyter-lab",
            "\(home)/miniconda3/bin/jupyter-lab",
            "\(home)/anaconda3/bin/jupyter-lab",
            "\(home)/miniforge3/bin/jupyter-lab",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static var isPythonAvailable: Bool { findPython3() != nil }
    static var isJupyterAvailable: Bool { findJupyterLab() != nil }

    /// Reset cached result (for testing).
    static func resetCache() {
        _cachedPython = nil
    }

    // MARK: - Private

    /// Check if a Python path is a real interpreter, not an Xcode/xcrun shim.
    private static func isRealPython(_ path: String) -> Bool {
        // /usr/bin/python3 is always the Xcode shim on macOS
        if path == "/usr/bin/python3" { return false }

        // Check if the file is a real binary (not a script that calls xcrun)
        guard let data = FileManager.default.contents(atPath: path),
              data.count > 4 else { return false }

        // Check for shebang that calls xcrun
        if let header = String(data: data.prefix(200), encoding: .utf8),
           header.contains("xcrun") {
            return false
        }

        return true
    }
}
