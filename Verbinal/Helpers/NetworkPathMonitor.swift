// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Network
import Observation
import os.log

/// Live network connectivity status for the app.
///
/// Wraps `NWPathMonitor` and projects its updates onto an `@Observable`
/// shim that views can read directly. Tracks both presence (any path) and
/// transition events (Wi-Fi → Ethernet, VPN connect / disconnect) so the
/// UI can surface a "Network changed — please retry" hint when in-flight
/// requests get cut.
///
/// Lifecycle: a single instance lives on `AppState`. `start()` is called
/// once at launch; `stop()` runs in `deinit`. The monitor itself is on a
/// background dispatch queue per Apple's pattern.
@Observable
@MainActor
final class NetworkPathMonitor {

    enum Connectivity: Sendable, Equatable {
        case unknown
        case satisfied
        case unsatisfied
    }

    enum Interface: Sendable, Equatable {
        case wifi
        case wired
        case cellular
        case loopback
        case other
    }

    /// Current connectivity state. Updated on the main actor as the system
    /// publishes path changes.
    private(set) var connectivity: Connectivity = .unknown
    /// Active interface (Wi-Fi / Ethernet / Cellular). Useful for the UI to
    /// say "Switched from Wi-Fi to Ethernet" rather than just "Network
    /// changed".
    private(set) var interface: Interface = .other
    /// Monotonic counter — each path change bumps it. Views can `.onChange`
    /// of this to toast "Network changed; retrying…".
    private(set) var changeCount: Int = 0

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "NetworkPath")
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.codebg.Verbinal.NetworkPathMonitor")
    private var started = false

    init() {
        self.monitor = NWPathMonitor()
    }

    deinit {
        // Cancellation is idempotent; safe to call even if start() never ran.
        monitor.cancel()
    }

    /// Begin observing path changes. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Hop to MainActor — the published state is read by SwiftUI views.
            Task { @MainActor in
                self.apply(path: path)
            }
        }
        monitor.start(queue: queue)
    }

    /// Stop observing. Subsequent `start()` calls are no-ops; create a new
    /// instance if you need to restart.
    func stop() {
        monitor.cancel()
    }

    private func apply(path: NWPath) {
        let newConnectivity: Connectivity = path.status == .satisfied ? .satisfied : .unsatisfied
        let newInterface = Self.classify(path: path)

        let connectivityChanged = newConnectivity != connectivity
        let interfaceChanged = newInterface != interface

        connectivity = newConnectivity
        interface = newInterface
        if connectivityChanged || interfaceChanged {
            changeCount &+= 1
            Self.logger.info("Network path changed: connectivity=\(String(describing: newConnectivity), privacy: .public) interface=\(String(describing: newInterface), privacy: .public) (#\(self.changeCount))")
        }
    }

    private static func classify(path: NWPath) -> Interface {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.loopback) { return .loopback }
        return .other
    }
}
