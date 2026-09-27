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
///
/// The relaying — and keeping the assistant's session alive while the app
/// is closed, starts or quits — is `ResilientBridge`'s; this file only
/// supplies the stdio side, the way to the app's socket, and the words.
enum MCPStdioBridge {
    static func runAndExit() -> Never {
        // Ignore SIGPIPE process-wide: an MCP client can close stdout while
        // a write is in flight; we want EPIPE on `write(2)`, not death.
        signal(SIGPIPE, SIG_IGN)
        BridgeLog.info("mcp bridge startup pid=\(getpid())")
        let sem = DispatchSemaphore(value: 0)
        Task {
            let bridge = ResilientBridge(
                client: StdioTransport(),
                connect: connectToApp,
                manifest: .standard(),
                configuration: .init(
                    serverName: "Verbinal",
                    serverVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                    notRunningMessage: notRunningMessage),
                log: { BridgeLog.info($0) })
            await bridge.run()
            sem.signal()
        }
        sem.wait()
        BridgeLog.info("mcp bridge shutting down")
        exit(0)
    }

    /// What an assistant reads while Verbinal is closed.
    static let notRunningMessage = "Verbinal is not running. Open Verbinal and turn on Settings ▸ AI Agent ▸ Allow external AI agents; its tools come back on their own once it is running."

    /// The running app's socket, or nil while it is closed.
    @Sendable
    private static func connectToApp() async -> (any MCPTransport)? {
        guard let socketPath = try? SocketSidecar.read() else { return nil }
        let socket = SocketTransport.client(socketPath: socketPath)
        do {
            try await socket.start()
            BridgeLog.info("connected to \(socketPath)")
            return socket
        } catch {
            BridgeLog.info("connect to \(socketPath) failed — \(error)")
            return nil
        }
    }
}

// MARK: - stderr logger
//
// Claude Desktop captures the server's stderr into
// `~/Library/Logs/Claude/mcp-server-verbinal-canfar.log`, so anything here
// is grepable diagnostic evidence without opening Console.app.

private enum BridgeLog {
    static func info(_ message: @autoclosure () -> String) { emit("info", message()) }

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
#endif
