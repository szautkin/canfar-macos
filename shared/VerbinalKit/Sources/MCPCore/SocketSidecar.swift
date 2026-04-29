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

    /// Sidecar file name (inside the per-app subdirectory).
    public static let fileName = "mcp.sock-path"

    public enum Error: Swift.Error, Equatable {
        case applicationSupportUnavailable
        case sidecarMissing
        case malformedSidecar
        case ioFailure(String)
    }

    // MARK: - Path resolution

    /// All Application Support directories the sidecar might live in.
    /// Returned in *write* preference order (the first entry is where the
    /// host app should write); readers should consult them all.
    ///
    /// Why two: the sandboxed app stores under
    /// `~/Library/Containers/<bundle>/Data/Library/Application Support/`,
    /// while the unsandboxed development build stores under the regular
    /// `~/Library/Application Support/`. The helper is unsandboxed and
    /// must resolve either.
    public static func candidateDirectories() -> [URL] {
        var paths: [URL] = []

        // Sandboxed location: synthesised from the home dir; the helper
        // can't use FileManager.url(for: .applicationSupportDirectory…)
        // because that resolves to the *helper's* own container, not the
        // app's. We construct the path explicitly.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sandboxed = home
            .appendingPathComponent("Library/Containers/\(appBundleID)/Data/Library/Application Support/\(appBundleID)", isDirectory: true)
        paths.append(sandboxed)

        // Unsandboxed development location: regular ~/Library/Application Support.
        let unsandboxed = home
            .appendingPathComponent("Library/Application Support/\(appBundleID)", isDirectory: true)
        paths.append(unsandboxed)

        return paths
    }

    /// Returns the directory the *running app* should write into. When
    /// called from inside the host app, `FileManager` resolves the correct
    /// container automatically.
    public static func appWriteDirectory() throws -> URL {
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

    /// Read the socket path the host app last wrote. Probes the candidate
    /// directories in order; first hit wins.
    public static func read() throws -> String {
        for dir in candidateDirectories() {
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

    /// Build a fresh socket path under the app's Application Support
    /// directory. Includes the process ID so concurrent dev builds don't
    /// collide. Note: the path's containing directory must exist; the
    /// caller is expected to invoke `appWriteDirectory()` first if not.
    public static func suggestedSocketPath() -> String {
        let dir = (try? appWriteDirectory()) ?? FileManager.default.temporaryDirectory
        let pid = ProcessInfo.processInfo.processIdentifier
        return dir.appendingPathComponent("mcp-\(pid).sock").path
    }
}
