// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Discovers Python and Jupyter installations on the system.
enum PythonDiscovery {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "PythonDiscovery")

    /// Known search paths for Python/Jupyter.
    private static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    /// Find the jupyter-lab executable path.
    static func findJupyterLab() -> String? {
        // Check PATH first
        if let path = findInPath("jupyter-lab") { return path }

        // Check common conda locations
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let condaPaths = [
            "\(home)/miniconda3/bin/jupyter-lab",
            "\(home)/anaconda3/bin/jupyter-lab",
            "\(home)/miniforge3/bin/jupyter-lab",
            "\(home)/.conda/bin/jupyter-lab",
        ]
        for path in condaPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                logger.info("Found jupyter-lab at \(path)")
                return path
            }
        }

        // Check known search paths
        for dir in searchPaths {
            let path = "\(dir)/jupyter-lab"
            if FileManager.default.isExecutableFile(atPath: path) {
                logger.info("Found jupyter-lab at \(path)")
                return path
            }
        }

        logger.warning("jupyter-lab not found")
        return nil
    }

    /// Find Python 3 executable.
    static func findPython3() -> String? {
        if let path = findInPath("python3") { return path }
        for dir in searchPaths {
            let path = "\(dir)/python3"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Check if jupyter-lab is available.
    static var isJupyterAvailable: Bool {
        findJupyterLab() != nil
    }

    private static func findInPath(_ executable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executable]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, process.terminationStatus == 0 {
                return path
            }
        } catch {
            // which not available
        }
        return nil
    }
}
