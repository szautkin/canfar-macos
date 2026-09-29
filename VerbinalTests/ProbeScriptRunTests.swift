// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// The probe script, run for real on this Mac, as QA's astroai/improc had
/// it (plan 19 K1, QA N4): the python3 first on PATH a build of its own
/// with only pip, the packages belonging to /usr/bin/python3. Every
/// interpreter is asked for its own.
final class ProbeScriptRunTests: XCTestCase {

    private func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testEveryPythonInterpreterIsAskedForItsPackages() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
              (try? run("/usr/bin/python3", ["-c", "import importlib.metadata"])) == 0 else {
            throw XCTSkip("no working /usr/bin/python3 here")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin"), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // The python3 on PATH: a build of its own that has only pip.
        let fake = bin.appendingPathComponent("python3")
        try """
        #!/bin/sh
        if [ "$1" = "-c" ]; then
            case "$2" in "import importlib.metadata"*) echo "pip|26.2.1"; exit 0;; esac
        fi
        exec /usr/bin/python3 "$@"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let script = root.appendingPathComponent("probe.sh")
        try ProbeScript.body.write(to: script, atomically: true, encoding: .utf8)

        let status = try run("/bin/bash", [script.path], environment: [
            "PATH": "\(bin.path):/usr/bin:/bin", "HOME": home.path, "IMAGE_ID": "test/improc:latest"])
        XCTAssertEqual(status, 0)
        let out = home.appendingPathComponent(".verbinal/manifests/test_improc_latest.json")
        let manifest = try ManifestParser.parse(try Data(contentsOf: out))

        XCTAssertEqual(manifest.schemaVersion, 4)
        let onPath = manifest.pythonPackages.filter { $0.env.isEmpty }
        XCTAssertEqual(onPath.map(\.name), ["pip"], "the python3 on PATH, env \"\"")
        let others = manifest.pythonPackages.filter { !$0.env.isEmpty }
        XCTAssertFalse(others.isEmpty, "/usr/bin/python3's packages are listed too, by its path")
        XCTAssertTrue(others.allSatisfy { $0.env.hasSuffix("python3") || $0.env.contains("python") }, "\(Set(others.map(\.env)))")
    }
}
