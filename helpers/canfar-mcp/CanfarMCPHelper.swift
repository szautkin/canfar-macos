// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// canfar-mcp — stateless transport adapter between an MCP client (e.g.
// Claude Desktop, which spawns this process and pipes JSON-RPC over
// stdio) and the running Verbinal app (which listens on a Unix socket
// whose path is published in a sidecar file under App Support).
//
// Lifecycle:
//   1. Read the sidecar file. If absent or unreadable, drain stdin and
//      respond -32000 to every request — the app isn't running, but a
//      well-behaved client will still see well-formed JSON-RPC errors.
//   2. Connect to the socket. If the connect fails, same fallback.
//   3. Splice stdin↔socket bidirectionally. Exit when either side ends.
//
// No state. No retries (Claude Desktop will respawn us if it cares).
// All durable state lives on the app side.

import Foundation
import Darwin
import MCPCore
import os.log

@main
struct CanfarMCPHelper {
    static func main() async {
        // Ignore SIGPIPE process-wide. MCP clients (Claude Desktop in
        // particular) can close stdout while a write is in flight; the
        // default SIGPIPE handler would kill us mid-frame. Letting
        // `write(2)` return EPIPE instead lets the regular error path
        // run cleanly. Must happen before any I/O.
        signal(SIGPIPE, SIG_IGN)

        HelperLog.info("startup pid=\(getpid())")
        await Forwarder().run()
        HelperLog.info("shutting down")
        exit(0)
    }
}

// MARK: - stderr logger
//
// Claude Desktop captures the helper's stderr into
// `~/Library/Logs/Claude/mcp-server-verbinal-canfar.log`. Anything we
// write here becomes diagnostic evidence the user (or another Claude
// session) can grep without opening Console.app.

enum HelperLog {
    static func debug(_ message: @autoclosure () -> String) { emit("debug", message()) }
    static func info(_ message: @autoclosure () -> String)  { emit("info",  message()) }
    static func error(_ message: @autoclosure () -> String) { emit("error", message()) }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Fallback diagnostic channel used only when stderr itself fails to
    /// write — so the helper's diagnostics don't vanish without a trace.
    private static let fallback = Logger(subsystem: "com.codebg.Verbinal.canfar-mcp", category: "helper")

    private static func emit(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [canfar-mcp] [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try FileHandle.standardError.write(contentsOf: data)
        } catch {
            // stderr is the helper's sole diagnostic surface (captured by
            // Claude Desktop). If it breaks, route to the unified log rather
            // than dropping the line silently.
            fallback.log("\(line, privacy: .public)")
        }
    }
}

/// Encapsulates the helper's three states (connecting, forwarding,
/// failing). Pulled into a separate type so the lifecycle is readable.
private actor Forwarder {

    func run() async {
        let stdio = StdioTransport()

        let socketPath: String
        do {
            socketPath = try SocketSidecar.read()
            HelperLog.info("sidecar resolved -> \(socketPath)")
        } catch {
            HelperLog.error("sidecar missing — \(error)")
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
            HelperLog.info("socket connected")
        } catch {
            HelperLog.error("connect failed — \(error)")
            await drainAndFail(
                stdio: stdio,
                code: JSONRPCErrorCode.serviceUnavailable,
                message: "Could not connect to Verbinal app."
            )
            return
        }

        HelperLog.info("entering forward loop")
        await splice(stdio: stdio, socket: socket)
        HelperLog.info("forward loop exited")
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
            // First one finished implies the link is broken; abandon the other.
            _ = await group.next()
            group.cancelAll()
        }
    }

    private static func copy(from src: any MCPTransport,
                             to dst: any MCPTransport,
                             label: String) async {
        do {
            for try await frame in src.incoming {
                let trace = Self.trace(of: frame)
                HelperLog.debug("\(label) \(frame.count)B \(trace)")
                try await dst.send(frame)
            }
        } catch {
            HelperLog.info("\(label) ended — \(error)")
        }
    }

    /// Best-effort one-line trace of a JSON-RPC frame. Parses just enough
    /// JSON to surface method + id; never decodes params/results so the
    /// log volume stays bounded even with 12 KB tools/list responses.
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
        if let method = obj["method"] as? String {
            return "method=\(method) id=\(id)"
        }
        if obj["result"] != nil {
            return "response result id=\(id)"
        }
        if obj["error"] != nil {
            return "response error id=\(id)"
        }
        return "id=\(id)"
    }

    /// Read every incoming request and respond with the same error so the
    /// client gets well-formed JSON-RPC instead of mysterious silence.
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
                do {
                    let bytes = try encoder.encode(response)
                    try await stdio.send(bytes)
                } catch {
                    // The whole point of drainAndFail is to never leave the
                    // client in silence — so if the error response itself
                    // can't be delivered, say so on the diagnostic channel
                    // and keep draining the next frame.
                    HelperLog.error("failed to send error response for id \(request.id): \(error)")
                }
            }
        } catch {
            // EOF or framing failure — peer hung up; we're done.
        }
    }
}
