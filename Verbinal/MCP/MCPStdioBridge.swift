// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// stdio↔unix-socket bridge, run when the app binary is launched with the
// `mcp` argument (by Claude Desktop or another MCP client that spawns the
// server as a child and pipes JSON-RPC over stdio).
//
// WHY THIS LIVES IN THE MAIN APP BINARY (not a separate helper)
// ------------------------------------------------------------
// The earlier design bundled a bare command-line helper (`canfar-mcp`) and
// pointed Claude Desktop at it. That works in development but is impossible
// in a Mac App Store distribution build:
//
//   * A MAS-embedded executable may carry ONLY `app-sandbox` + `inherit`.
//     An `inherit` process has no sandbox of its own — it must inherit one
//     from a sandboxed parent. Claude Desktop is a foreign, non-sandboxed
//     parent, so the helper dies at launch ("not in an inherited sandbox",
//     SIGTRAP from libsystem_secinit).
//   * A bare Mach-O cannot embed a provisioning profile, so under macOS 15
//     App Group "container protection" it has no way to authorize its
//     `com.apple.security.application-groups` claim, and cannot reach the
//     shared socket.
//
// The MAIN APP BINARY has neither limitation: it is the bundle's primary
// executable, so the bundle's `embedded.provisionprofile` authorizes the
// App Group (container-protection criterion D), it carries a FULL sandbox
// (not `inherit`) so it stands up its own sandbox regardless of who
// launched it, and it is the App-Store-deployed, Team-ID-prefixed entity
// (criteria A and C). So when Claude Desktop launches
// `…/Verbinal.app/Contents/MacOS/Verbinal mcp`, this code runs with App
// Group access and bridges Claude's stdio to the running GUI instance's
// unix socket — exactly what the bundled helper used to do, but in the one
// process the sandbox will actually authorize.

#if os(macOS)
import Foundation
import MCPCore

/// Entry point invoked from `VerbinalMain` when the `mcp` argument is
/// present. Runs the bridge to completion, then terminates the process —
/// it never returns to the SwiftUI app path.
enum MCPStdioBridge {
    static func runAndExit() -> Never {
        // Ignore SIGPIPE process-wide: an MCP client can close stdout while
        // a write is in flight; we want EPIPE on `write(2)`, not death.
        signal(SIGPIPE, SIG_IGN)
        BridgeLog.info("mcp bridge startup pid=\(getpid())")
        let sem = DispatchSemaphore(value: 0)
        Task {
            await Bridge().run()
            sem.signal()
        }
        sem.wait()
        BridgeLog.info("mcp bridge shutting down")
        exit(0)
    }
}

// MARK: - stderr logger
//
// Claude Desktop captures the server's stderr into
// `~/Library/Logs/Claude/mcp-server-verbinal-canfar.log`, so anything here
// is grepable diagnostic evidence without opening Console.app.

private enum BridgeLog {
    static func debug(_ message: @autoclosure () -> String) { emit("debug", message()) }
    static func info(_ message: @autoclosure () -> String)  { emit("info",  message()) }
    static func error(_ message: @autoclosure () -> String) { emit("error", message()) }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func emit(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [verbinal-mcp] [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

/// Three states: connecting, forwarding, failing. Mirrors the old helper's
/// `Forwarder` so behaviour (graceful JSON-RPC errors when the app isn't
/// running) is identical.
private actor Bridge {

    func run() async {
        let stdio = StdioTransport()

        let socketPath: String
        do {
            socketPath = try SocketSidecar.read()
            BridgeLog.info("sidecar resolved -> \(socketPath)")
        } catch {
            BridgeLog.error("sidecar missing — \(error)")
            await drainAndFail(
                stdio: stdio,
                code: JSONRPCErrorCode.serviceUnavailable,
                message: "Verbinal app is not running."
            )
            return
        }

        let socket = SocketTransport.client(socketPath: socketPath)
        do {
            try await socket.start()
            BridgeLog.info("socket connected")
        } catch {
            BridgeLog.error("connect failed — \(error)")
            await drainAndFail(
                stdio: stdio,
                code: JSONRPCErrorCode.serviceUnavailable,
                message: "Could not connect to Verbinal app."
            )
            return
        }

        BridgeLog.info("entering forward loop")
        await splice(stdio: stdio, socket: socket)
        BridgeLog.info("forward loop exited")
        await stdio.close()
        await socket.close()
    }

    /// Bidirectional stdin↔socket bridge. Returns when either side closes.
    private func splice(stdio: StdioTransport, socket: SocketTransport) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.copy(from: stdio, to: socket, label: "stdio→socket")
            }
            group.addTask {
                await Self.copy(from: socket, to: stdio, label: "socket→stdio")
            }
            // First finished implies the link is broken; abandon the other.
            _ = await group.next()
            group.cancelAll()
        }
    }

    private static func copy(from src: any MCPTransport,
                             to dst: any MCPTransport,
                             label: String) async {
        do {
            for try await frame in src.incoming {
                BridgeLog.debug("\(label) \(frame.count)B \(Self.trace(of: frame))")
                try await dst.send(frame)
            }
        } catch {
            BridgeLog.info("\(label) ended — \(error)")
        }
    }

    /// Best-effort one-line trace of a JSON-RPC frame (method + id only).
    private static func trace(of frame: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return "<non-json>"
        }
        let id: String
        switch obj["id"] {
        case let n as Int:    id = String(n)
        case let n as Int64:  id = String(n)
        case let s as String: id = "\"\(s)\""
        case is NSNull:       id = "null"
        default:              id = "-"
        }
        if let method = obj["method"] as? String { return "method=\(method) id=\(id)" }
        if obj["result"] != nil { return "response result id=\(id)" }
        if obj["error"] != nil { return "response error id=\(id)" }
        return "id=\(id)"
    }

    /// Read every incoming request and respond with the same error so the
    /// client gets well-formed JSON-RPC instead of silence.
    private func drainAndFail(stdio: StdioTransport, code: Int, message: String) async {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        do {
            for try await frame in stdio.incoming {
                guard let request = try? decoder.decode(JSONRPCRequest.self, from: frame) else {
                    continue // skip notifications and malformed bodies
                }
                let payload = JSONRPCErrorPayload(code: code, message: message)
                let response = JSONRPCResponse.failure(id: request.id, error: payload)
                if let bytes = try? encoder.encode(response) {
                    try? await stdio.send(bytes)
                } else {
                    BridgeLog.error("failed to encode error response for id \(request.id)")
                }
            }
        } catch {
            // EOF / framing failure — peer hung up; done.
        }
    }
}
#endif
