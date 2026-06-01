// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Discovery contract between the host app and the `canfar-mcp` helper.
///
/// On listener-open the app writes its current unix-socket path into a
/// well-known sidecar file; on launch the helper reads the same file and
/// connects there. The path indirection lets us:
///
///   * Hand out a fresh socket path per app launch (so a stale socket
///     left over from a crashed previous run never confuses a new one).
///   * Place the socket inside the app's `App Support` container so a
///     sandboxed (Mac App Store) build can still reach it.
///   * Probe both the sandboxed and unsandboxed Application Support
///     locations from the helper without baking in `Bundle.main` paths
///     that don't apply outside the app process.
///
/// File contents are ASCII: a single line with the absolute socket path,
/// terminated by a newline. Writes go through a temp file + atomic rename
/// so a partially written sidecar can never be observed.
public enum SocketSidecar {

    /// Bundle ID under which the sidecar lives. Both the host app and the
    /// helper agree on this string.
    public static let appBundleID = "com.codebg.Verbinal"

    /// macOS App Group identifier shared between the host app and the
    /// `canfar-mcp` helper. Both targets declare
    /// `com.apple.security.application-groups` with this value so the
    /// helper — which lives in its *own* sandbox container when launched
    /// by Claude Desktop — can still read/write the sidecar file and
    /// connect to the unix socket the host writes there.
    ///
    /// macOS app group IDs must be team-ID prefixed (unlike iOS, which
    /// uses the `group.` prefix). Registered in Apple Developer portal
    /// against both `com.codebg.Verbinal` and `com.codebg.Verbinal.canfar-mcp`.
    public static let appGroupID = "A4ABW5VD88.com.codebg.Verbinal"

    /// Sidecar file name (inside the per-app subdirectory).
    public static let fileName = "mcp.sock-path"

    public enum Error: Swift.Error, Equatable {
        case applicationSupportUnavailable
        case sidecarMissing
        case malformedSidecar
        case ioFailure(String)
    }

    // MARK: - Path resolution

    /// App Group container shared between host and helper. Returns nil
    /// when neither process has the entitlement (e.g., legacy unsandboxed
    /// dev builds, or unit tests outside an entitled process) — callers
    /// fall back to the legacy per-bundle paths below.
    public static func groupContainerDirectory() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    /// All directories the sidecar might live in, in read-probe order.
    /// First hit wins. The group container is preferred; legacy paths
    /// remain as fallback so older dev builds (or a transition build
    /// where one side hasn't been redeployed) keep working.
    public static func candidateDirectories() -> [URL] {
        var paths: [URL] = []

        // Preferred: shared App Group container. Same path for both
        // host app and sandboxed helper.
        if let group = groupContainerDirectory() {
            paths.append(group)
        }

        // Legacy: host app's Application Support inside its container.
        // The helper can no longer read this once it's sandboxed (its
        // own container is at a different path), but we keep it as a
        // read fallback for transitional builds.
        //
        // macOS-only: iOS has no per-app Library/Containers path and no
        // `homeDirectoryForCurrentUser`. The App Group container above is
        // the only valid location on iOS.
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sandboxed = home
            .appendingPathComponent("Library/Containers/\(appBundleID)/Data/Library/Application Support/\(appBundleID)", isDirectory: true)
        paths.append(sandboxed)

        // Legacy: unsandboxed Application Support — only relevant for
        // pre-MAS Developer ID dev builds where neither process is
        // sandboxed.
        let unsandboxed = home
            .appendingPathComponent("Library/Application Support/\(appBundleID)", isDirectory: true)
        paths.append(unsandboxed)
        #endif

        return paths
    }

    /// Directory the *running app* should write the sidecar into. Uses
    /// the App Group container when available so the sandboxed helper
    /// can read it; falls back to legacy Application Support for dev
    /// builds without the App Group entitlement.
    public static func appWriteDirectory() throws -> URL {
        if let group = groupContainerDirectory() {
            do {
                try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
                return group
            } catch {
                throw Error.ioFailure("appWriteDirectory(group): \(error.localizedDescription)")
            }
        }
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent(appBundleID, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            throw Error.ioFailure("appWriteDirectory: \(error.localizedDescription)")
        }
    }

    // MARK: - Read / write

    /// Read the socket path the host app last wrote. Probes `directories`
    /// in order; first hit wins. Tests pass a non-default list so a
    /// real running app's sidecar can't shadow the test's own writes.
    public static func read(directories: [URL] = SocketSidecar.candidateDirectories()) throws -> String {
        for dir in directories {
            let url = dir.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: url),
               let line = String(data: data, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw Error.malformedSidecar }
                return trimmed
            }
        }
        throw Error.sidecarMissing
    }

    /// Atomically write the socket path. Called by the host app when its
    /// listener becomes ready. Returns the URL written to so callers can
    /// surface it for diagnostics.
    @discardableResult
    public static func write(socketPath: String) throws -> URL {
        let dir = try appWriteDirectory()
        let target = dir.appendingPathComponent(fileName)
        let line = socketPath + "\n"
        guard let data = line.data(using: .utf8) else {
            throw Error.ioFailure("non-utf8 socket path")
        }
        do {
            try data.write(to: target, options: [.atomic])
        } catch {
            throw Error.ioFailure("write \(target.path): \(error.localizedDescription)")
        }
        return target
    }

    /// Remove the sidecar file (best-effort; missing file is not an error).
    public static func clear() {
        if let dir = try? appWriteDirectory() {
            let target = dir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// Build a fresh socket path. Prefers the App Group container so
    /// the sandboxed helper can `connect()` to it; falls back to the
    /// process-local temp directory for unsandboxed dev builds.
    ///
    /// POSIX `sockaddr_un.sun_path` on Darwin is capped at 104 bytes,
    /// so paths longer than ~100 chars get rejected with ENAMETOOLONG.
    /// The Group Containers prefix
    /// `~/Library/Group Containers/<group-id>/` runs ~75 chars before
    /// the file name; comfortably under the limit.
    /// Includes the PID so concurrent dev runs don't collide.
    public static func suggestedSocketPath() -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        if let group = groupContainerDirectory() {
            let candidate = group.appendingPathComponent("mcp-\(pid).sock").path
            if candidate.utf8.count <= 100 { return candidate }
        }
        let tmp = FileManager.default.temporaryDirectory
        let candidate = tmp.appendingPathComponent("mcp-\(pid).sock").path
        if candidate.utf8.count <= 100 { return candidate }
        // Fallback for environments with absurdly long temp paths
        // (e.g., custom $TMPDIR): drop into /tmp directly even if the
        // sandbox doesn't normally let us write there. POSIX bind will
        // surface a clear error, which the user will see verbatim now
        // that MCPTransportError conforms to LocalizedError.
        return "/tmp/canfar-mcp-\(pid).sock"
    }
}
