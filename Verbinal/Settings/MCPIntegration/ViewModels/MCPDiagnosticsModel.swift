// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import Foundation
import Observation
import Darwin            // SIGTRAP
import MCPCore           // SocketSidecar, SocketTransport

/// Drives the MCP integration diagnostics: a battery of fast synchronous
/// checks plus an on-demand helper launch self-test. `@Observable @MainActor`;
/// owned by the settings tab as `@State`. Heavy/blocking work (spawning the
/// helper, blocking pipe reads) runs on a detached task so the main actor
/// never stalls.
@Observable @MainActor
final class MCPDiagnosticsModel {
    private let agents: AgentsService
    private let settings: MCPIntegrationSettingsService

    private(set) var checks: [DiagnosticCheck] = []
    private(set) var selfTest: DiagnosticCheck?
    private(set) var isRunningSelfTest = false
    /// Non-fatal error from a Fix / Configure action, surfaced to the user.
    var actionError: String?
    /// Set after a successful merge so the UI can prompt a Claude restart.
    private(set) var didUpdateConfig = false

    init(agents: AgentsService, settings: MCPIntegrationSettingsService) {
        self.agents = agents
        self.settings = settings
    }

    // MARK: - Run all checks (synchronous — every check is a fast read)

    func runAll() {
        var out: [DiagnosticCheck] = []

        // 1. Server enabled (user preference)
        out.append(agents.isEnabled
            ? check("serverEnabled", "MCP server enabled", .pass, "External AI agents are allowed.")
            : check("serverEnabled", "MCP server enabled", .fail, "Turn on “Allow external AI agents”.", fix: .enableServer))

        // 2. Listener running
        if agents.isEnabled {
            out.append(agents.isRunning
                ? check("serverRunning", "Listener running", .pass, "The socket server is up.")
                : check("serverRunning", "Listener running", .fail, "Server is enabled but the listener didn’t come up.", fix: .restartServer))
        } else {
            out.append(check("serverRunning", "Listener running", .warn, "Skipped — server disabled.", fix: .enableServer))
        }

        // 3. Listener error
        if let err = agents.lastError {
            out.append(check("listenerError", "Listener health", .fail, "\(err) (may be from a previous session).", fix: .restartServer))
        } else {
            out.append(check("listenerError", "Listener health", .pass, "No listener errors."))
        }

        // 4. App Group container resolves (the entitlement the helper shares)
        if SocketSidecar.groupContainerDirectory() != nil {
            out.append(check("appGroup", "App Group container", .pass, "Shared container resolves (\(SocketSidecar.appGroupID))."))
        } else {
            out.append(check("appGroup", "App Group container", .fail, "App Group \(SocketSidecar.appGroupID) does not resolve — entitlement/provisioning issue."))
        }

        // 5. Socket path published + file present
        if agents.isRunning {
            if let path = agents.socketPath {
                out.append(FileManager.default.fileExists(atPath: path)
                    ? check("socketPublished", "Socket published", .pass, path)
                    : check("socketPublished", "Socket published", .warn, "Path set but socket file is missing: \(path)", fix: .restartServer))
            } else {
                out.append(check("socketPublished", "Socket published", .fail, "Running but no socket path.", fix: .restartServer))
            }
        } else {
            out.append(check("socketPublished", "Socket published", .warn, "Skipped — listener not running."))
        }

        // 6. Sidecar readable + matches the live socket
        out.append(sidecarCheck())

        // 7. Tools registered (snapshotted at listener start)
        let n = agents.tools.count
        out.append(n > 0
            ? check("toolsRegistered", "Tools registered", .pass, "\(n) tool\(n == 1 ? "" : "s") registered at listener start.")
            : check("toolsRegistered", "Tools registered", .fail, "No tools registered — restart the listener.", fix: .restartServer))

        // 8. Claude Desktop installed
        if let app = settings.claudeAppURL() {
            out.append(check("claudeInstalled", "Claude Desktop installed", .pass, app.path))
        } else {
            out.append(check("claudeInstalled", "Claude Desktop installed", .warn, "Claude Desktop not found (other MCP clients still work).", fix: .openClaude))
        }

        // 9. Config registered + path matches this build's helper
        out.append(configCheck())

        checks = out
    }

    private func sidecarCheck() -> DiagnosticCheck {
        do {
            let path = try SocketSidecar.read()
            if let live = agents.socketPath, path == live {
                return check("sidecar", "Sidecar published", .pass, "Points at the live socket.")
            } else if agents.isRunning {
                return check("sidecar", "Sidecar published", .warn, "Sidecar (\(path)) differs from the live socket — stale.", fix: .restartServer)
            } else {
                return check("sidecar", "Sidecar published", .warn, "Sidecar present (\(path)) but listener not running.")
            }
        } catch {
            return check("sidecar", "Sidecar published", agents.isRunning ? .fail : .warn,
                         "Sidecar not readable: \(error).", fix: agents.isRunning ? .restartServer : nil)
        }
    }

    private func configCheck() -> DiagnosticCheck {
        let helperPath = (try? settings.resolveHelperPath()) ?? MCPIntegrationSettingsService.helperURL.path
        switch settings.probeConfig() {
        case .noAccess:
            return check("config", "Claude config registered", .warn,
                         "Grant access to the Claude folder to check/repair the config.", fix: .grantConfigAccess)
        case .unreadable(let why):
            return check("config", "Claude config registered", .warn, "Config not readable: \(why).", fix: .grantConfigAccess)
        case .fileMissing:
            return check("config", "Claude config registered", .fail,
                         "No claude_desktop_config.json yet — create the entry.", fix: .updateConfig)
        case .noEntry:
            return check("config", "Claude config registered", .fail,
                         "No “\(MCPIntegrationSettingsService.serverKey)” entry — add it.", fix: .updateConfig)
        case .entry(let command):
            if command == helperPath {
                return command.contains("/DerivedData/")
                    ? check("config", "Claude config registered", .warn, "Points at a dev build: \(command)")
                    : check("config", "Claude config registered", .pass, "Points at this app’s helper.")
            } else {
                return check("config", "Claude config registered", .warn,
                             "Points elsewhere (\(command)) — update to this build.", fix: .updateConfig)
            }
        }
    }

    private func check(_ id: String, _ title: String, _ status: DiagnosticStatus,
                       _ detail: String, fix: FixAction? = nil) -> DiagnosticCheck {
        DiagnosticCheck(id: id, title: title, status: status, detail: detail, fix: fix)
    }

    // MARK: - Fix dispatch

    func applyFix(_ fix: FixAction) {
        actionError = nil
        switch fix {
        case .enableServer:
            agents.isEnabled = true
            runAll()
        case .restartServer:
            restartServer()
        case .grantConfigAccess:
            do { try settings.grantConfigAccess(); runAll() }
            catch let e as MCPConfigError where e == .cancelled { /* user dismissed */ }
            catch { actionError = (error as? MCPConfigError)?.errorDescription ?? error.localizedDescription }
        case .updateConfig:
            updateConfig()
        case .revealHelper:
            settings.revealHelperInFinder()
        case .openClaude:
            settings.openClaude()
        }
    }

    /// Primary "Configure Claude Desktop" action: grant if needed, then merge.
    func configureClaude() {
        actionError = nil
        do {
            if !settings.hasConfigAccess { try settings.grantConfigAccess() }
            try settings.mergeVerbinalEntry()
            didUpdateConfig = true
            runAll()
        } catch let e as MCPConfigError where e == .cancelled {
            // user dismissed the panel — nothing to do
        } catch {
            actionError = (error as? MCPConfigError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func updateConfig() {
        do {
            try settings.mergeVerbinalEntry()
            didUpdateConfig = true
            runAll()
        } catch {
            actionError = (error as? MCPConfigError)?.errorDescription ?? error.localizedDescription
        }
    }

    func restartServer() {
        agents.isEnabled = false   // synchronous stopServer() in didSet
        // @MainActor-isolate the closure explicitly: it touches @MainActor
        // state (agents.isEnabled, runAll) after the suspension point.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)  // let serverLoopTask cancellation settle
            guard let self else { return }
            self.agents.isEnabled = true                     // synchronous startServer()
            self.runAll()
        }
    }

    // MARK: - Helper launch self-test

    func runSelfTest() async {
        guard agents.isEnabled, agents.isRunning, let socketPath = agents.socketPath else {
            selfTest = check("selfTest", "Helper launch self-test", .fail,
                             "Start the MCP server first (Allow external AI agents).", fix: .enableServer)
            return
        }
        let helperPath: String
        do { helperPath = try settings.resolveHelperPath() }
        catch {
            selfTest = check("selfTest", "Helper launch self-test", .fail,
                             (error as? MCPConfigError)?.errorDescription ?? "\(error)", fix: .revealHelper)
            return
        }

        isRunningSelfTest = true
        selfTest = check("selfTest", "Helper launch self-test", .running, "Spawning canfar-mcp…")
        defer { isRunningSelfTest = false }

        // Mode A: spawn the real helper (blocking I/O off the main actor).
        let outcome = await Task.detached { Self.performSpawnProbe(helperPath: helperPath) }.value

        if case .spawnDenied(let reason) = outcome {
            // Mode B: socket loopback — exercises app↔socket↔router, not the binary.
            let lb = await Self.performLoopbackProbe(socketPath: socketPath)
            selfTest = selfTestCheck(lb, viaLoopback: true, spawnReason: reason)
        } else {
            selfTest = selfTestCheck(outcome, viaLoopback: false, spawnReason: nil)
        }
    }

    private func selfTestCheck(_ outcome: SelfTestOutcome, viaLoopback: Bool, spawnReason: String?) -> DiagnosticCheck {
        let suffix = viaLoopback ? " (loopback — sandbox blocked spawning: \(spawnReason ?? "?"); helper binary not exercised)" : ""
        switch outcome {
        case .ok(let info):
            return check("selfTest", "Helper launch self-test", viaLoopback ? .warn : .pass,
                         "initialize round-trip OK — \(info)\(suffix)")
        case .sigtrap:
            return check("selfTest", "Helper launch self-test", .fail,
                         "Helper killed by SIGTRAP — it can’t initialize its sandbox container (missing embedded Info.plist / code-sign issue). The app needs rebuilding/updating.", fix: .revealHelper)
        case .signal(let s):
            return check("selfTest", "Helper launch self-test", .fail, "Helper crashed with signal \(s).", fix: .revealHelper)
        case .exited(let code, let stderr):
            let tail = stderr.isEmpty ? "" : " — \(stderr.suffix(200))"
            return check("selfTest", "Helper launch self-test", .fail, "Helper exited \(code)\(tail)\(suffix)")
        case .timeout:
            return check("selfTest", "Helper launch self-test", .warn,
                         "No response within timeout — helper started but didn’t answer\(suffix).", fix: .restartServer)
        case .helperMissing(let p):
            return check("selfTest", "Helper launch self-test", .fail, "Helper not found/executable at \(p).", fix: .revealHelper)
        case .spawnDenied(let r):
            return check("selfTest", "Helper launch self-test", .warn, "Could not spawn helper: \(r).")
        }
    }

    // MARK: - Probes (nonisolated — run off the main actor)

    /// Spawn the bundled helper, send `initialize` over its stdio (ndjson),
    /// read the first line, and classify. Synchronous/blocking — call from a
    /// detached task. Distinguishes SIGTRAP (sandbox-container failure) from a
    /// clean round-trip, and reports `.spawnDenied` if the sandbox refuses to
    /// launch the helper at all (→ caller falls back to loopback).
    nonisolated static func performSpawnProbe(helperPath: String) -> SelfTestOutcome {
        let url = URL(fileURLWithPath: helperPath)
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { return .helperMissing(helperPath) }

        let proc = Process()
        proc.executableURL = url
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do { try proc.run() }
        catch { return .spawnDenied(error.localizedDescription) }

        // ndjson initialize frame (StdioTransport is newline-delimited).
        if let body = try? JSONSerialization.data(withJSONObject: initializeRequest()) {
            var frame = body; frame.append(0x0A)
            try? stdinPipe.fileHandleForWriting.write(contentsOf: frame)
        }

        // Read the first ndjson line, bounded by a 5s deadline.
        var buf = Data()
        let deadline = Date().addingTimeInterval(5)
        let outFH = stdoutPipe.fileHandleForReading
        while Date() < deadline {
            let chunk = outFH.availableData      // blocks until data or EOF
            if chunk.isEmpty { break }           // EOF — helper closed/died
            buf.append(chunk)
            if buf.firstIndex(of: 0x0A) != nil { break }
        }
        try? stdinPipe.fileHandleForWriting.close()   // EOF → a healthy helper exits 0

        // Did we get a usable response?
        if let nl = buf.firstIndex(of: 0x0A),
           let obj = try? JSONSerialization.jsonObject(with: Data(buf[..<nl])) as? [String: Any] {
            if obj["result"] != nil {
                if proc.isRunning { proc.terminate() }
                return .ok(serverInfo: serverInfoString(obj))
            }
            if let err = obj["error"] as? [String: Any] {
                if proc.isRunning { proc.terminate() }
                return .exited(code: 0, stderr: "initialize error: \(err["message"] as? String ?? "unknown")")
            }
        }

        // No response — let it settle, then inspect how it ended without
        // ever blocking unbounded (terminate() can, rarely, fail to reap).
        var weTerminated = false
        let killBy = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < killBy { usleep(50_000) }
        if proc.isRunning {
            weTerminated = true
            proc.terminate()
            let reapBy = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < reapBy { usleep(20_000) }
        }
        // Still alive → unkillable; can't read a meaningful status, so bail.
        guard !proc.isRunning else { return .timeout }

        if !weTerminated && proc.terminationReason == .uncaughtSignal {
            return proc.terminationStatus == SIGTRAP ? .sigtrap : .signal(proc.terminationStatus)
        }
        let errText = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        if !weTerminated && proc.terminationStatus != 0 {
            return .exited(code: proc.terminationStatus, stderr: errText)
        }
        return .timeout
    }

    /// Spawn-free fallback: dial the app's own live socket and round-trip an
    /// `initialize`. Validates app↔socket↔router but NOT the helper binary.
    nonisolated static func performLoopbackProbe(socketPath: String) async -> SelfTestOutcome {
        let client = SocketTransport.client(socketPath: socketPath)
        do { try await client.start() }
        catch { return .exited(code: -1, stderr: "connect: \(error.localizedDescription)") }
        guard let body = try? JSONSerialization.data(withJSONObject: initializeRequest()) else {
            await client.close(); return .timeout
        }
        do { try await client.send(body) }
        catch { await client.close(); return .exited(code: -1, stderr: "send: \(error.localizedDescription)") }

        let outcome: SelfTestOutcome = await withTaskGroup(of: SelfTestOutcome.self) { group in
            group.addTask {
                do {
                    for try await data in client.incoming {
                        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if obj["result"] != nil { return .ok(serverInfo: serverInfoString(obj)) }
                        if let err = obj["error"] as? [String: Any] {
                            return .exited(code: 0, stderr: err["message"] as? String ?? "error")
                        }
                    }
                } catch { return .exited(code: -1, stderr: error.localizedDescription) }
                return .timeout
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
        await client.close()
        return outcome
    }

    private nonisolated static func initializeRequest() -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "VerbinalSelfTest", "version": "1.0"],
            ],
        ]
    }

    private nonisolated static func serverInfoString(_ obj: [String: Any]) -> String {
        guard let result = obj["result"] as? [String: Any],
              let info = result["serverInfo"] as? [String: Any] else { return "ok" }
        let name = info["name"] as? String ?? "server"
        let version = info["version"] as? String ?? "?"
        return "\(name) \(version)"
    }
}
#endif
