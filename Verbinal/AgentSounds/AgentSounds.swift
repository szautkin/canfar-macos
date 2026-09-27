// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AVFoundation
import Foundation
import Observation

/// The two moments worth a sound.
enum AgentCue: CaseIterable, Sendable {
    /// An agent has started calling tools.
    case started
    /// It has gone quiet again.
    case finished

    var fileName: String { self == .started ? "agent-start" : "agent-stop" }
}

/// A stream of tool calls as the two moments worth hearing. An agent at
/// work calls many times a second; a sound on each would be a stutter, not
/// a cue — so only the edges count.
struct AgentCueTracker {
    private(set) var active = false

    /// A call: `.started` on the first after quiet, nil while it goes on.
    mutating func activity() -> AgentCue? {
        defer { active = true }
        return active ? nil : .started
    }

    /// Quiet for long enough: `.finished` once, nil when already quiet.
    mutating func idle() -> AgentCue? {
        defer { active = false }
        return active ? .finished : nil
    }
}

/// Two short sounds, so an agent's arrival and departure are noticed
/// without being watched for — by someone reading a paper in another
/// window. That is the whole scope: two cues and a switch. The files are
/// the ones Verbinal for Windows and Linux play, so the apps sound alike.
@Observable
@MainActor
final class AgentSounds {
    private static let enabledKey = "com.codebg.Verbinal.agents.sounds"
    /// How long without a call before the agent counts as gone quiet —
    /// the snackbar's own burst window.
    nonisolated static let quietAfter: Duration = .seconds(2.5)

    var isEnabled: Bool {
        didSet { if persists { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) } }
    }

    @ObservationIgnored private var tracker = AgentCueTracker()
    @ObservationIgnored private var quietTimer: Task<Void, Never>?
    /// One player per cue, reused: replaying rewinds it rather than
    /// stacking a second sound over the first.
    @ObservationIgnored private var players: [AgentCue: AVAudioPlayer] = [:]
    @ObservationIgnored private let persists: Bool
    /// Where a test hears the cues instead of the speaker.
    @ObservationIgnored private let heard: (@MainActor (AgentCue) -> Void)?

    /// `enabledOverride` and `heard` are for tests: in memory, and silent.
    init(enabledOverride: Bool? = nil, heard: (@MainActor (AgentCue) -> Void)? = nil) {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        persists = enabledOverride == nil
        isEnabled = enabledOverride ?? UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.heard = heard
    }

    /// An agent called a tool.
    func agentCalled() {
        if let cue = tracker.activity() { cueIfEnabled(cue) }
        quietTimer?.cancel()
        quietTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.quietAfter)
            guard !Task.isCancelled, let self, let cue = self.tracker.idle() else { return }
            self.cueIfEnabled(cue)
        }
    }

    /// Read per cue, so turning them off takes effect on the next one.
    private func cueIfEnabled(_ cue: AgentCue) {
        guard isEnabled else { return }
        if let heard { heard(cue) } else { sound(cue) }
    }

    /// Silent in every case it cannot play — switched off, not bundled, no
    /// audio device: an app that made noise about not making a noise would
    /// be worse than quiet.
    private func sound(_ cue: AgentCue) {
        if players[cue] == nil,
           let url = Bundle.main.url(forResource: cue.fileName, withExtension: "wav"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = 0.6
            players[cue] = player
        }
        guard let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }
}
