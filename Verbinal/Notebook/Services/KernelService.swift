// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Manages a Python subprocess for code execution via the kernel harness protocol.
actor KernelService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Kernel")
    private static let sentinel = "\u{04}__CANFAR_EXEC_BOUNDARY__\u{04}"

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var state: KernelState = .stopped

    func getState() -> KernelState { state }

    /// Start the Python kernel subprocess.
    func start() async throws {
        guard case .stopped = state else { return }

        guard let pythonPath = PythonDiscovery.findPython3() else {
            state = .error("Python 3 not found")
            throw KernelError.pythonNotFound
        }

        // Write harness to temp location
        let harnessPath = try writeHarness()

        state = .starting
        Self.logger.info("Starting kernel with \(pythonPath)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-u", harnessPath]
        proc.environment = ProcessInfo.processInfo.environment
        proc.environment?["PYTHONIOENCODING"] = "utf-8"
        proc.environment?["PYTHONUNBUFFERED"] = "1"

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        process = proc
        stdinPipe = stdin
        stdoutPipe = stdout

        // Wait for initial idle sentinel
        let _ = try await readUntilBoundary()
        state = .idle
        Self.logger.info("Kernel started")

        // Monitor for termination
        Task {
            proc.waitUntilExit()
            Self.logger.info("Kernel exited with code \(proc.terminationStatus)")
            self.state = .stopped
            self.process = nil
        }
    }

    /// Execute code and return outputs.
    func execute(code: String, execCount: Int) async throws -> [CellOutput] {
        guard let stdin = stdinPipe else { throw KernelError.notRunning }

        state = .busy

        let request = ["type": "execute", "code": code, "exec_count": execCount] as [String: Any]
        let jsonData = try JSONSerialization.data(withJSONObject: request)
        var line = jsonData
        line.append(contentsOf: "\n".utf8)
        stdin.fileHandleForWriting.write(line)

        let messages = try await readUntilBoundary()

        var outputs: [CellOutput] = []
        for msg in messages {
            guard let dict = msg as? [String: Any],
                  let type = dict["type"] as? String else { continue }

            switch type {
            case "stream":
                let name = dict["name"] as? String ?? "stdout"
                let text = dict["text"] as? String ?? ""
                outputs.append(CellOutput(
                    type: name == "stderr" ? .stderr : .stdout,
                    text: text,
                    imageBase64: nil
                ))

            case "execute_result":
                if let data = dict["data"] as? [String: Any],
                   let text = data["text/plain"] as? String {
                    outputs.append(CellOutput(type: .result, text: text, imageBase64: nil))
                }

            case "display_data":
                if let data = dict["data"] as? [String: Any] {
                    if let b64 = data["image/png"] as? String {
                        outputs.append(CellOutput(type: .image, text: "", imageBase64: b64))
                    } else if let text = data["text/plain"] as? String {
                        outputs.append(CellOutput(type: .result, text: text, imageBase64: nil))
                    }
                }

            case "error":
                let ename = dict["ename"] as? String ?? "Error"
                let evalue = dict["evalue"] as? String ?? ""
                let tb = (dict["traceback"] as? [String])?.joined(separator: "\n") ?? ""
                outputs.append(CellOutput(
                    type: .error,
                    text: tb.isEmpty ? "\(ename): \(evalue)" : tb,
                    imageBase64: nil
                ))

            case "status":
                if let st = dict["state"] as? String {
                    state = st == "busy" ? .busy : .idle
                }

            default:
                break
            }
        }

        state = .idle
        return outputs
    }

    /// Stop the kernel.
    func stop() {
        if let stdin = stdinPipe {
            let quit = "{\"type\":\"quit\"}\n".data(using: .utf8)!
            stdin.fileHandleForWriting.write(quit)
        }
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        state = .stopped
    }

    var isRunning: Bool {
        if case .stopped = state { return false }
        if case .error = state { return false }
        return true
    }

    // MARK: - Private

    private func writeHarness() throws -> String {
        guard let harnessURL = Bundle.main.url(forResource: "kernel_harness", withExtension: "py") else {
            // Fallback: write from embedded string
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Verbinal")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let path = tempDir.appendingPathComponent("kernel_harness.py").path
            // If already written, reuse
            if FileManager.default.fileExists(atPath: path) { return path }
            throw KernelError.harnessNotFound
        }
        return harnessURL.path
    }

    private func readUntilBoundary() async throws -> [Any] {
        guard let stdout = stdoutPipe else { throw KernelError.notRunning }

        return try await withCheckedThrowingContinuation { continuation in
            var messages: [Any] = []
            var accumulated = ""

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    continuation.resume(returning: messages)
                    return
                }

                guard let text = String(data: data, encoding: .utf8) else { return }
                accumulated += text

                while let newlineIdx = accumulated.firstIndex(of: "\n") {
                    let line = String(accumulated[accumulated.startIndex..<newlineIdx])
                    accumulated = String(accumulated[accumulated.index(after: newlineIdx)...])

                    if line.contains(Self.sentinel) {
                        handle.readabilityHandler = nil
                        continuation.resume(returning: messages)
                        return
                    }

                    if let data = line.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) {
                        messages.append(json)
                    }
                }
            }

            // Timeout
            Task {
                try? await Task.sleep(for: .seconds(60))
                stdout.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: KernelError.timeout)
            }
        }
    }
}

enum KernelError: LocalizedError {
    case pythonNotFound
    case notRunning
    case harnessNotFound
    case timeout

    var errorDescription: String? {
        switch self {
        case .pythonNotFound: return "Python 3 not found on this system"
        case .notRunning: return "Kernel is not running"
        case .harnessNotFound: return "Kernel harness script not found in app bundle"
        case .timeout: return "Kernel execution timed out"
        }
    }
}
