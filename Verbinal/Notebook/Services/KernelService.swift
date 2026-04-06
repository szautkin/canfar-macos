// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Manages a Python subprocess for code execution via the kernel harness protocol.
/// Uses a dedicated reader thread to avoid pipe race conditions.
actor KernelService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Kernel")
    private static let sentinel = "\u{04}__CANFAR_EXEC_BOUNDARY__\u{04}"

    private var process: Process?
    private var stdinPipe: Pipe?
    private var messageStream: AsyncStream<[Any]>?
    private var messageContinuation: AsyncStream<[Any]>.Continuation?
    private var state: KernelState = .stopped

    func getState() -> KernelState { state }

    /// Start the Python kernel subprocess.
    func start() async throws {
        guard case .stopped = state else { return }

        guard let pythonPath = PythonDiscovery.findPython3() else {
            state = .error("Python 3 not found")
            throw KernelError.pythonNotFound
        }

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
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Ignore SIGPIPE so we don't crash if the pipe breaks
        signal(SIGPIPE, SIG_IGN)

        try proc.run()
        process = proc
        stdinPipe = stdin

        // Set up the message stream with a background reader thread
        let (stream, continuation) = AsyncStream<[Any]>.makeStream()
        messageStream = stream
        messageContinuation = continuation

        startReaderThread(handle: stdout.fileHandleForReading, continuation: continuation)

        // Wait for initial idle sentinel
        for await batch in stream {
            // First batch is the initial idle status — kernel is ready
            _ = batch
            break
        }

        state = .idle
        Self.logger.info("Kernel started")

        // Monitor for termination
        Task.detached { [weak self] in
            proc.waitUntilExit()
            Self.logger.info("Kernel exited with code \(proc.terminationStatus)")
            await self?.handleExit()
        }
    }

    private func handleExit() {
        state = .stopped
        process = nil
        messageContinuation?.finish()
    }

    /// Execute code and return outputs.
    func execute(code: String, execCount: Int) async throws -> [CellOutput] {
        guard let stdin = stdinPipe, let stream = messageStream else {
            throw KernelError.notRunning
        }

        state = .busy

        let request: [String: Any] = ["type": "execute", "code": code, "exec_count": execCount]
        let jsonData = try JSONSerialization.data(withJSONObject: request)
        var line = jsonData
        line.append(contentsOf: "\n".utf8)
        stdin.fileHandleForWriting.write(line)

        // Wait for the next batch of messages (until boundary)
        var outputs: [CellOutput] = []
        for await batch in stream {
            outputs = parseMessages(batch)
            break // one batch per execute
        }

        state = .idle
        return outputs
    }

    /// Stop the kernel.
    func stop() {
        if let stdin = stdinPipe {
            let quit = "{\"type\":\"quit\"}\n".data(using: .utf8)!
            try? stdin.fileHandleForWriting.write(contentsOf: quit)
        }
        process?.terminate()
        process = nil
        stdinPipe = nil
        messageContinuation?.finish()
        messageStream = nil
        messageContinuation = nil
        state = .stopped
    }

    var isRunning: Bool {
        if case .stopped = state { return false }
        if case .error = state { return false }
        return true
    }

    // MARK: - Background Reader Thread

    /// Reads stdout line by line on a background thread. Groups messages between sentinels
    /// and yields each group as an array through the AsyncStream.
    private nonisolated func startReaderThread(
        handle: FileHandle,
        continuation: AsyncStream<[Any]>.Continuation
    ) {
        Thread.detachNewThread {
            var buffer = Data()
            var currentBatch: [Any] = []

            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break } // EOF

                buffer.append(chunk)

                // Process complete lines
                while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                    let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                    buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                    guard let lineStr = String(data: lineData, encoding: .utf8) else { continue }
                    let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }

                    if trimmed.contains(Self.sentinel) {
                        // Boundary found — yield current batch
                        continuation.yield(currentBatch)
                        currentBatch = []
                    } else if let data = trimmed.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) {
                        currentBatch.append(json)
                    }
                }
            }

            // EOF — yield remaining and finish
            if !currentBatch.isEmpty {
                continuation.yield(currentBatch)
            }
            continuation.finish()
        }
    }

    // MARK: - Message Parsing

    private func parseMessages(_ messages: [Any]) -> [CellOutput] {
        var outputs: [CellOutput] = []
        for msg in messages {
            guard let dict = msg as? [String: Any],
                  let type = dict["type"] as? String else { continue }

            switch type {
            case "stream":
                let name = dict["name"] as? String ?? "stdout"
                let text = dict["text"] as? String ?? ""
                outputs.append(CellOutput(type: name == "stderr" ? .stderr : .stdout, text: text, imageBase64: nil))

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
                outputs.append(CellOutput(type: .error, text: tb.isEmpty ? "\(ename): \(evalue)" : tb, imageBase64: nil))

            default:
                break
            }
        }
        return outputs
    }

    // MARK: - Harness

    private func writeHarness() throws -> String {
        if let harnessURL = Bundle.main.url(forResource: "kernel_harness", withExtension: "py") {
            return harnessURL.path
        }
        // Fallback: copy from source
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Verbinal")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destPath = tempDir.appendingPathComponent("kernel_harness.py").path
        if FileManager.default.fileExists(atPath: destPath) { return destPath }
        throw KernelError.harnessNotFound
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
