// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit
#endif
import Foundation
import MCPCore

/// The app's side of the sidecar — the file that tells `Verbinal mcp` which
/// socket to connect to (plan 36 2.2, 2.3). It writes it when the server
/// starts, writes it again when it names a socket nobody listens at (a
/// test host's, a crashed run's), and removes it only while it is the
/// app's own. A sidecar naming another Verbinal that is listening is left
/// to it.
@MainActor
final class SidecarKeeper {
    private(set) var socketPath: String?
    private var watching: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    private let directory: URL?
    private let interval: Duration

    /// `directory` nil is the shared one; tests pass their own.
    init(directory: URL? = nil, interval: Duration = .seconds(60)) {
        self.directory = directory
        self.interval = interval
    }

    /// The server listens at `path`: the sidecar names it, and keeps naming it.
    func serving(at path: String) throws {
        socketPath = path
        try SocketSidecar.write(socketPath: path, directory: directory)
        #if os(macOS)
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.check() }
        }
        #endif
        watching = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.check()
            }
        }
    }

    /// The server stopped: the sidecar goes, if it is still the app's.
    func stopped() {
        watching?.cancel()
        watching = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        if let socketPath { SocketSidecar.clear(ifNaming: socketPath, directory: directory) }
        socketPath = nil
    }

    /// The sidecar names this app's socket again, when it names nothing or a
    /// socket nobody listens at. True when it was written.
    @discardableResult
    func check() -> Bool {
        guard let socketPath else { return false }
        let named = try? SocketSidecar.read(directories: directory.map { [$0] } ?? SocketSidecar.candidateDirectories())
        guard named != socketPath, named.map({ !SocketSidecar.isListening($0) }) ?? true else { return false }
        return (try? SocketSidecar.write(socketPath: socketPath, directory: directory)) != nil
    }
}
