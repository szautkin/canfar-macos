// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Metal
#if canImport(Darwin)
import Darwin
#endif

/// Where to send someone who wants the app, help, or to report a bug — the
/// APP's home, not the observatory it talks to.
enum AppLinks {
    static let website = URL(string: "https://verbinal.com")!
    static let help = URL(string: "https://github.com/szautkin/canfar-macos#readme")!
    static let newIssue = URL(string: "https://github.com/szautkin/canfar-macos/issues/new")!
}

/// What was actually running, read at RUN time, as a bug report wants it:
/// the app, the OS build, the machine and its architecture, the GPU, the
/// memory, and how it was installed — each from its own source, each as
/// text someone can paste. Nothing throws and nothing is left out: a value
/// that cannot be read says so, since a missing line reads as an answer.
enum RuntimeInfo {
    struct Fact: Equatable, Sendable {
        let name: String
        let value: String
    }

    static func facts() -> [Fact] {
        [
            Fact(name: "App", value: appVersion()),
            Fact(name: "OS", value: operatingSystem()),
            Fact(name: "Machine", value: machine()),
            Fact(name: "Architecture", value: architecture()),
            Fact(name: "GPU", value: MTLCreateSystemDefaultDevice()?.name ?? "none found"),
            Fact(name: "Memory", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)),
            Fact(name: "Install", value: install()),
        ]
    }

    /// The facts as one block, for Copy: a report gets pasted, not retyped.
    static func text(_ facts: [Fact]) -> String {
        facts.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// "1.4.0 (14)" — the version people see and the build that identifies it.
    static func appVersion(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        return (info?["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
    }

    /// "macOS Version 26.0 (Build 25A354)" — the build is what a bug is reproduced against.
    static func operatingSystem() -> String {
        #if os(macOS)
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
    }

    /// The model identifier, e.g. "Mac15,3".
    static func machine() -> String {
        sysctlString("hw.model") ?? "unknown"
    }

    /// The process's architecture — and "under Rosetta" when it is x86_64
    /// on Apple silicon, which changes what a graphics bug means and is
    /// invisible from anywhere else in a report.
    static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        return rosetta ? "x86_64 under Rosetta on Apple silicon" : "x86_64"
        #endif
    }

    /// How it got here: half the paths in a sandboxed app branch on it.
    static func install() -> String {
        #if DEBUG
        return "development build"
        #elseif os(macOS)
        let receipt = Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        return FileManager.default.fileExists(atPath: receipt.path) ? "Mac App Store" : "outside the App Store"
        #else
        return "App Store"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
