// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// Live, transient signal of "an agent is using the app right now",
/// driving the top-of-window agent-activity snackbar. Fed by a push
/// audit sink on EVERY tool dispatch (reads included), matching the
/// Windows client's robot-icon snackbar.
///
/// Distinct from ``AgentActivityStore`` (the persistent, write/proposal
/// breadcrumb the wand popover and per-row badges read): this is
/// ephemeral, covers reads too, and exists only to flash a banner.
///
/// Bursts coalesce: rapid calls from the same agent within
/// ``burstWindow`` collapse into one banner with a running count
/// ("claude-ai · 4 tool calls") instead of a flicker storm. The banner
/// auto-hides ``lingerSeconds`` after the last call.
@Observable
@MainActor
final class AgentLiveActivity {
    /// The banner currently shown, or nil when idle.
    private(set) var banner: Banner?

    /// Whether the snackbar is enabled at all (Settings toggle).
    var isEnabled: Bool

    struct Banner: Equatable, Identifiable {
        let id: UUID
        /// Agent label, e.g. `claude-ai/0.1.0`.
        var originLabel: String
        /// The most recent tool called in this burst.
        var latestTool: String
        /// How many calls have collapsed into this banner.
        var count: Int
        /// When the burst started (drives the id/animation identity).
        let startedAt: Date
    }

    /// Calls within this window from the same agent collapse together.
    private let burstWindow: TimeInterval = 2.5
    /// Banner lingers this long after the last call, then hides.
    private let lingerSeconds: TimeInterval = 3.0

    private var lastCallAt: Date?
    private var hideTask: Task<Void, Never>?

    private static let enabledKey = "com.codebg.Verbinal.agents.showActivitySnackbar"

    init(enabledOverride: Bool? = nil) {
        if let enabledOverride {
            self.isEnabled = enabledOverride
        } else {
            // Default ON — the whole point is visibility of agent action.
            UserDefaults.standard.register(defaults: [Self.enabledKey: true])
            self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        if !value {
            hideTask?.cancel()
            banner = nil
        }
    }

    /// Record one agent tool call. `now` is injectable for tests
    /// (`Date.now`/`Math.random` are only restricted in workflow
    /// scripts, not app code, but an injectable clock keeps the burst
    /// logic testable without sleeps).
    func record(originLabel: String, toolName: String, at now: Date = Date()) {
        guard isEnabled else { return }

        if var current = banner,
           current.originLabel == originLabel,
           let last = lastCallAt,
           now.timeIntervalSince(last) <= burstWindow {
            // Same agent, still bursting — coalesce.
            current.count += 1
            current.latestTool = toolName
            banner = current
        } else {
            // New burst (or different agent).
            banner = Banner(
                id: UUID(),
                originLabel: originLabel,
                latestTool: toolName,
                count: 1,
                startedAt: now)
        }
        lastCallAt = now
        scheduleHide()
    }

    /// Dismiss the banner immediately (user clicked the ✕).
    func dismiss() {
        hideTask?.cancel()
        banner = nil
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let linger = lingerSeconds
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }
}
