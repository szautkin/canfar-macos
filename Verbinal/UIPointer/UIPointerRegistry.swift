// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// The controls an agent can point at right now, and the hint it is
/// pointing with — the answer to "where is that setting?" being the app
/// itself pointing at it. Views register what they show with
/// `.pointable(_:label:)`; the overlay draws the hint.
@Observable
@MainActor
final class UIPointerRegistry {

    struct Hint: Equatable {
        let targetID: String
        let message: String?
        let serial: Int
    }

    static let defaultSeconds = 8.0
    static let secondsRange = 2.0...60.0

    private(set) var targets: [String: UIPointerMatcher.Target] = [:]
    private(set) var hint: Hint?
    private var serial = 0

    func register(_ target: UIPointerMatcher.Target) { targets[target.id] = target }

    /// Leaving a screen takes its targets — and any hint on them — along.
    func unregister(_ id: String) {
        targets[id] = nil
        if hint?.targetID == id { hint = nil }
    }

    enum Outcome: Equatable {
        case pointed(UIPointerMatcher.Target)
        case notFound(candidates: [UIPointerMatcher.Target])
    }

    /// Points at the one control `query` names, for `seconds` (clamped).
    func point(at query: String, message: String?, seconds: Double?) -> Outcome {
        let all = Array(targets.values)
        guard let target = UIPointerMatcher.best(all, for: query) else {
            return .notFound(candidates: UIPointerMatcher.candidates(all, for: query))
        }
        serial += 1
        let mine = serial
        hint = Hint(targetID: target.id, message: message?.isEmpty == false ? message : nil, serial: mine)
        let wait = min(max(seconds ?? Self.defaultSeconds, Self.secondsRange.lowerBound), Self.secondsRange.upperBound)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            if self?.hint?.serial == mine { self?.hint = nil }
        }
        return .pointed(target)
    }

    func clearHint() { hint = nil }
}
