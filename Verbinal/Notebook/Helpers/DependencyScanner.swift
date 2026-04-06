// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Scans notebook cells for Python import statements and identifies missing packages.
enum DependencyScanner {

    /// Known standard library modules (not installable via pip).
    private static let stdlib: Set<String> = [
        "abc", "argparse", "ast", "asyncio", "base64", "bisect", "calendar",
        "collections", "colorsys", "concurrent", "configparser", "contextlib",
        "copy", "csv", "ctypes", "dataclasses", "datetime", "decimal",
        "difflib", "dis", "email", "enum", "errno", "fileinput", "fnmatch",
        "fractions", "functools", "gc", "getpass", "glob", "gzip", "hashlib",
        "heapq", "hmac", "html", "http", "importlib", "inspect", "io",
        "itertools", "json", "keyword", "linecache", "locale", "logging",
        "lzma", "math", "mimetypes", "multiprocessing", "numbers", "operator",
        "os", "pathlib", "pickle", "platform", "plistlib", "pprint",
        "profile", "queue", "random", "re", "readline", "reprlib", "secrets",
        "select", "shelve", "shutil", "signal", "site", "socket", "sqlite3",
        "ssl", "stat", "statistics", "string", "struct", "subprocess", "sys",
        "tempfile", "textwrap", "threading", "time", "timeit", "token",
        "tokenize", "traceback", "types", "typing", "unicodedata", "unittest",
        "urllib", "uuid", "venv", "warnings", "weakref", "xml", "xmlrpc",
        "zipfile", "zipimport", "zlib", "_thread", "__future__",
    ]

    /// Known module name → pip package name mappings.
    private static let packageMap: [String: String] = [
        "PIL": "Pillow",
        "cv2": "opencv-python",
        "sklearn": "scikit-learn",
        "skimage": "scikit-image",
        "yaml": "PyYAML",
        "bs4": "beautifulsoup4",
        "dateutil": "python-dateutil",
        "attr": "attrs",
        "serial": "pyserial",
        "usb": "pyusb",
        "gi": "PyGObject",
        "wx": "wxPython",
    ]

    /// Extract top-level module names from import statements in source code.
    static func extractImports(from sources: [String]) -> Set<String> {
        var modules: Set<String> = []

        for source in sources {
            for line in source.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // import X, Y, Z
                if trimmed.hasPrefix("import ") {
                    let rest = String(trimmed.dropFirst(7))
                    for part in rest.components(separatedBy: ",") {
                        let module = part.trimmingCharacters(in: .whitespaces)
                            .components(separatedBy: " ").first?  // handle "import X as Y"
                            .components(separatedBy: ".").first ?? ""
                        if !module.isEmpty { modules.insert(module) }
                    }
                }

                // from X import Y
                if trimmed.hasPrefix("from ") {
                    let rest = String(trimmed.dropFirst(5))
                    let module = rest.components(separatedBy: " ").first?
                        .components(separatedBy: ".").first ?? ""
                    if !module.isEmpty { modules.insert(module) }
                }
            }
        }

        return modules
    }

    /// Filter to only third-party packages (not in stdlib).
    static func thirdPartyModules(from modules: Set<String>) -> [String] {
        modules.filter { !stdlib.contains($0) && !$0.hasPrefix("_") }
            .sorted()
    }

    /// Map module name to pip package name.
    static func pipPackageName(for module: String) -> String {
        packageMap[module] ?? module
    }

    /// Check which packages are installed by running pip list.
    static func checkInstalled(packages: [String], pythonPath: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-m", "pip", "list", "--format=columns"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            var installed: Set<String> = []
            for line in output.components(separatedBy: .newlines) {
                let name = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces).first ?? ""
                if !name.isEmpty {
                    installed.insert(name.lowercased())
                }
            }
            return installed
        } catch {
            return []
        }
    }

    /// Find missing packages for a notebook's code cells.
    static func findMissing(sources: [String], pythonPath: String) -> [String] {
        let imports = extractImports(from: sources)
        let thirdParty = thirdPartyModules(from: imports)
        let pipNames = thirdParty.map { pipPackageName(for: $0) }

        guard !pipNames.isEmpty else { return [] }

        let installed = checkInstalled(packages: pipNames, pythonPath: pythonPath)
        return pipNames.filter { !installed.contains($0.lowercased()) }
    }
}
