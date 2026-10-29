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
import os

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
        let identity = RelayIdentity.thisRelay()
        BridgeLog.info("mcp bridge startup pid=\(identity.pid) launched by \(identity.parentName ?? "?") (\(identity.parentPID))")
        let sem = DispatchSemaphore(value: 0)
        Task {
            let bridge = ResilientBridge(
                client: StdioTransport(),
                connect: connectToApp,
                manifest: .standard(),
                configuration: .init(
                    serverName: "Verbinal",
                    serverVersion: identity.version,
                    notRunningMessage: notRunningMessage,
                    instructions: AgentSession.instructions,
                    whyClosed: { lastMiss.withLock { $0?.message } },
                    identity: identity),
                log: { BridgeLog.info($0) })
            // It ends with the client that launched it, even one that never
            // closes its pipe (plan 52 A1)…
            let client = ProcessExitWatch(pid: identity.parentPID) {
                Task { await bridge.stop(clientQuit) }
            }
            if getppid() != identity.parentPID { await bridge.stop(clientQuit) }
            // …and looks for Verbinal as soon as it announces itself (A2).
            let announcements = SocketSidecar.groupContainerDirectory().flatMap { folder in
                FolderWatch(directory: folder) { Task { await bridge.appMayBeBack() } }
            }
            await bridge.run()
            withExtendedLifetime((client, announcements)) {}
            sem.signal()
        }
        sem.wait()
        BridgeLog.info("mcp bridge shutting down")
        exit(0)
    }

    /// Why a relay whose client has gone ends (plan 52 A1).
    static let clientQuit = "The assistant's client has quit."

    /// What an assistant reads while Verbinal is closed.
    static let notRunningMessage = "Verbinal is not running. Open Verbinal and turn on Settings ▸ AI Agent ▸ Allow external AI agents; its tools come back on their own once it is running."

    /// Why the last attempt found no app (plan 36 2.5): an assistant is told
    /// which, rather than to turn on a switch that is on.
    enum Miss: Equatable {
        /// No sidecar: Verbinal never served here, or its server is off.
        case noSidecar
        /// The sidecar names a server that has gone, and no other answers.
        case gone

        var message: String {
            switch self {
            case .noSidecar:
                "Verbinal is not running, or Settings ▸ AI Agent ▸ Allow external AI agents is off. Its tools come back on their own once it is running."
            case .gone:
                "Verbinal is not running: the server it last named has quit (Verbinal quit or crashed). Open Verbinal; its tools come back on their own. Settings ▸ AI Agent ▸ Diagnostics shows the server's state."
            }
        }
    }

    private static let lastMiss = OSAllocatedUnfairLock<Miss?>(initialState: nil)

    /// The running app's socket, or nil while it is closed. The sidecar's
    /// socket first; when it is gone, the newest few others a Verbinal opened
    /// here (plan 36 2.4, plan 52 A3).
    @Sendable
    private static func connectToApp() async -> (any MCPTransport)? {
        let named = try? SocketSidecar.read()
        var paths = named.map { [$0] } ?? []
        paths += SocketSidecar.socketsNewestFirst().filter { $0 != named }.prefix(3)
        for socketPath in paths {
            let socket = SocketTransport.client(socketPath: socketPath)
            guard (try? await socket.start()) != nil else { continue }
            BridgeLog.info("connected to \(socketPath)\(socketPath == named ? "" : " (the sidecar named \(named ?? "none"))")")
            lastMiss.withLock { $0 = nil }
            return socket
        }
        // One line when the reason changes, not one per try (plan 52 A3).
        let miss: Miss = named == nil ? .noSidecar : .gone
        let changed = lastMiss.withLock { last in
            defer { last = miss }
            return last != miss
        }
        if changed { BridgeLog.info("Verbinal unreachable (\(miss)); tried \(paths.count) socket\(paths.count == 1 ? "" : "s")") }
        return nil
    }
}

extension RelayIdentity {
    /// This process: a relay, launched by an assistant's client.
    static func thisRelay() -> RelayIdentity {
        let parent = getppid()
        var name = [CChar](repeating: 0, count: 256)
        let length = proc_name(parent, &name, UInt32(name.count))
        let info = Bundle.main.infoDictionary
        return RelayIdentity(pid: getpid(), started: Date(), parentPID: parent,
                             parentName: length > 0 ? String(cString: name) : nil,
                             version: info?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                             build: info?["CFBundleVersion"] as? String,
                             executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
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
