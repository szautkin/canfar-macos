// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import MetricKit
import os.log

/// Receives MetricKit's daily metric and diagnostic payloads on
/// behalf of the app. Subscribed once at launch from `AppState.init`.
///
/// MetricKit is Apple's first-party, opt-out-by-user crash / hang /
/// disk-write / energy reporter — payloads land here once every 24h
/// (and on demand from Xcode's Organizer). We do nothing with them
/// at runtime except log a one-line summary so a developer reading
/// Console.app sees that the pipeline is alive. The same payloads
/// are uploaded to App Store Connect's Diagnostics dashboard, which
/// is where post-launch crash triage actually happens.
///
/// Why not skip this and rely on App Store Connect alone? Because
/// MetricKit only delivers payloads to apps that subscribe — without
/// `add(_:)` we get nothing in the dashboard either.
///
/// Privacy: MetricKit data is on-device, anonymised, opt-in via the
/// system "Share with App Developers" toggle. Nothing leaves the
/// user's Mac via this subscriber; Apple's pipeline handles transport.
final class MetricKitSubscriber: NSObject, @unchecked Sendable, MXMetricManagerSubscriber {
    static let shared = MetricKitSubscriber()
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "MetricKit")

    private override init() { super.init() }

    /// Daily aggregated metrics (CPU time, memory peaks, disk writes,
    /// hang rate, app launch time). Useful for spotting regressions
    /// between releases.
    ///
    /// `MXMetricPayload` is iOS-only on older SDKs (it is unavailable on
    /// macOS in the Xcode 16.x SDK CI builds with), so this handler is
    /// gated to iOS to keep the source portable across toolchains. The
    /// diagnostic handler below remains active on macOS, where it carries
    /// the crash/hang reports that actually matter for post-launch triage.
    #if os(iOS)
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            Self.logger.notice("metrics window=\(payload.timeStampBegin..<payload.timeStampEnd, privacy: .public) bytes=\(payload.jsonRepresentation().count, privacy: .public)")
        }
    }
    #endif

    /// Individual incident reports — one entry per crash, hang,
    /// disk-write spike, or CPU-exception. The OS gathers and
    /// delivers these asynchronously after the next launch.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpuExceptions = payload.cpuExceptionDiagnostics?.count ?? 0
            let diskWrites = payload.diskWriteExceptionDiagnostics?.count ?? 0
            Self.logger.error("diagnostics crashes=\(crashes) hangs=\(hangs) cpuExceptions=\(cpuExceptions) diskWrites=\(diskWrites)")
        }
    }
}
