// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Manages a Python subprocess for code execution via the kernel harness protocol.
/// Defensive: all pipe writes are safe (no ObjC exception crashes), process death is handled.
actor KernelService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Kernel")
    private static let sentinel = "\u{04}__CANFAR_EXEC_BOUNDARY__\u{04}"

    private var process: Process?
    private var stdinHandle: FileHandle?
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

        let harnessPath = try resolveHarnessPath()

        state = .starting
        Self.logger.info("Starting kernel with \(pythonPath), harness: \(harnessPath)")

        // Ignore SIGPIPE globally so broken pipe doesn't kill the app
        signal(SIGPIPE, SIG_IGN)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-u", harnessPath]
        proc.environment = ProcessInfo.processInfo.environment
        proc.environment?["PYTHONIOENCODING"] = "utf-8"
        proc.environment?["PYTHONUNBUFFERED"] = "1"

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            state = .error("Failed to start Python: \(error.localizedDescription)")
            throw error
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting

        // Set up message stream with background reader
        let (stream, continuation) = AsyncStream<[Any]>.makeStream()
        messageStream = stream
        messageContinuation = continuation

        startReaderThread(handle: stdoutPipe.fileHandleForReading, continuation: continuation)

        // Log stderr in background for debugging
        startStderrLogger(handle: stderrPipe.fileHandleForReading)

        // Wait for initial idle sentinel (with timeout)
        let gotIdle = await waitForFirstBatch(stream: stream)
        if !gotIdle {
            cleanup()
            state = .error("Kernel failed to start (no idle signal)")
            throw KernelError.startupFailed
        }

        state = .idle
        Self.logger.info("Kernel started successfully")

        // Monitor for termination
        Task.detached { [weak self] in
            proc.waitUntilExit()
            Self.logger.info("Kernel exited with code \(proc.terminationStatus)")
            await self?.cleanup()
        }
    }

    /// Execute code and return outputs.
    func execute(code: String, execCount: Int) async throws -> [CellOutput] {
        guard let handle = stdinHandle, let stream = messageStream else {
            throw KernelError.notRunning
        }

        // Verify process is alive
        guard let proc = process, proc.isRunning else {
            cleanup()
            throw KernelError.notRunning
        }

        state = .busy

        let request: [String: Any] = ["type": "execute", "code": code, "exec_count": execCount]
        let jsonData = try JSONSerialization.data(withJSONObject: request)
        var line = jsonData
        line.append(contentsOf: "\n".utf8)

        // Safe write — catches ObjC NSFileHandleOperationException
        guard safePipeWrite(handle: handle, data: line) else {
            cleanup()
            throw KernelError.notRunning
        }

        // Wait for response batch
        var outputs: [CellOutput] = []
        for await batch in stream {
            outputs = parseMessages(batch)
            break
        }

        state = .idle
        return outputs
    }

    /// Stop the kernel gracefully.
    func stop() {
        if let handle = stdinHandle {
            let quit = Data("{\"type\":\"quit\"}\n".utf8)
            safePipeWrite(handle: handle, data: quit)
        }
        process?.terminate()
        cleanup()
    }

    var isRunning: Bool {
        if case .stopped = state { return false }
        if case .error = state { return false }
        return process?.isRunning == true
    }

    // MARK: - Private: Safe Pipe Write

    /// Write data to a FileHandle without crashing on broken pipe.
    /// FileHandle.write() throws ObjC NSException on broken pipe, which Swift can't catch.
    /// This uses POSIX write() directly instead.
    @discardableResult
    private nonisolated func safePipeWrite(handle: FileHandle, data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let ptr = buffer.baseAddress else { return false }
            let written = Darwin.write(handle.fileDescriptor, ptr, data.count)
            return written == data.count
        }
    }

    // MARK: - Private: Cleanup

    private func cleanup() {
        stdinHandle = nil
        process = nil
        messageContinuation?.finish()
        messageStream = nil
        messageContinuation = nil
        state = .stopped
    }

    // MARK: - Private: Harness Resolution

    private func resolveHarnessPath() throws -> String {
        // Try bundle first
        if let url = Bundle.main.url(forResource: "kernel_harness", withExtension: "py") {
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }

        // Fallback: write harness to temp from embedded source
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Verbinal")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let destURL = tempDir.appendingPathComponent("kernel_harness.py")

        // If already written and recent, reuse
        if FileManager.default.fileExists(atPath: destURL.path) {
            return destURL.path
        }

        // Try to find in project source (development builds)
        let sourceLocations = [
            Bundle.main.bundlePath + "/Contents/Resources/kernel_harness.py",
            Bundle.main.resourcePath.map { $0 + "/kernel_harness.py" },
        ].compactMap { $0 }

        for loc in sourceLocations {
            if FileManager.default.fileExists(atPath: loc) {
                return loc
            }
        }

        Self.logger.error("kernel_harness.py not found in bundle or temp")
        throw KernelError.harnessNotFound
    }

    // MARK: - Private: Background Readers

    private nonisolated func startReaderThread(
        handle: FileHandle,
        continuation: AsyncStream<[Any]>.Continuation
    ) {
        Thread.detachNewThread {
            var buffer = Data()
            var currentBatch: [Any] = []

            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break } // EOF — process died

                buffer.append(chunk)

                while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                    let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                    buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                    guard let lineStr = String(data: lineData, encoding: .utf8) else { continue }
                    let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }

                    if trimmed.contains(Self.sentinel) {
                        continuation.yield(currentBatch)
                        currentBatch = []
                    } else if let data = trimmed.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) {
                        currentBatch.append(json)
                    }
                }
            }

            if !currentBatch.isEmpty {
                continuation.yield(currentBatch)
            }
            continuation.finish()
        }
    }

    private nonisolated func startStderrLogger(handle: FileHandle) {
        Thread.detachNewThread {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    Self.logger.debug("Python stderr: \(text)")
                }
            }
        }
    }

    // MARK: - Private: Wait for First Batch

    private func waitForFirstBatch(stream: AsyncStream<[Any]>) async -> Bool {
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    // MARK: - Private: Message Parsing

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
}

enum KernelError: LocalizedError {
    case pythonNotFound
    case notRunning
    case harnessNotFound
    case startupFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .pythonNotFound: return "Python 3 not found on this system"
        case .notRunning: return "Kernel is not running"
        case .harnessNotFound: return "Kernel harness script not found in app bundle"
        case .startupFailed: return "Kernel failed to start"
        case .timeout: return "Kernel execution timed out"
        }
    }
}
