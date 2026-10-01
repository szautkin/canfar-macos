// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// The hints that are up, in their sets, and how long each stays (plan 27).
/// The one owner of what is shown: the tools add and clear, the overlay
/// draws, the tracker moves, the person closes — all through here.
@Observable
@MainActor
final class UIHintStore {
    /// In the order shown.
    private(set) var hints: [UIHint] = []
    private(set) var sets: [String: UIHintSet] = [:]

    /// When each hint goes; absent while it waits for the person, or is paused.
    @ObservationIgnored private var deadlines: [String: Date] = [:]
    /// What was left of a paused hint's time.
    @ObservationIgnored private var paused: [String: TimeInterval] = [:]
    @ObservationIgnored private var serial = 0

    /// A set has gone, the last of its hints however it went.
    struct Dismissed: Sendable, Equatable {
        let set: String
        let how: UIHintDismissal
    }
    nonisolated let dismissed = Observers<Dismissed>()

    static let defaultBubbleSeconds = 8.0
    static let defaultRingSeconds = 15.0
    static let secondsRange = 2.0...120.0

    var isEmpty: Bool { hints.isEmpty }

    func hints(in set: String) -> [UIHint] { hints.filter { $0.set == set } }

    // MARK: - Showing

    /// Shows `new` as one set. The same element twice replaces its hint; it
    /// never stacks. `replace` clears every hint first.
    func show(_ new: [UIHint], numbered: Bool, dim: Bool, seconds: Double?, replace: Bool,
              now: Date = Date()) -> String {
        if replace { clearAll(.replaced) }
        serial += 1
        let id = "s\(serial)"
        sets[id] = UIHintSet(id: id, numbered: numbered, dim: dim, seconds: seconds)
        let ids = Set(new.map(\.id))
        remove(where: { ids.contains($0.id) }, how: .replaced)
        for (index, hint) in new.enumerated() {
            let numbered = UIHint(id: hint.id, set: id, style: hint.style, title: hint.title, text: hint.text,
                                  number: numbered ? index + 1 : nil, frame: hint.frame, kind: hint.kind,
                                  screen: hint.screen, window: hint.window)
            hints.append(numbered)
            if let seconds {
                let clamped = min(max(seconds, Self.secondsRange.lowerBound), Self.secondsRange.upperBound)
                deadlines[hint.id] = now.addingTimeInterval(clamped)
            }
        }
        return id
    }

    /// The seconds a hint stays when none were asked for.
    static func seconds(asked: Double?, untilClosed: Bool, bubbles: Bool) -> Double? {
        if untilClosed { return nil }
        let wanted = asked ?? (bubbles ? defaultBubbleSeconds : defaultRingSeconds)
        return min(max(wanted, secondsRange.lowerBound), secondsRange.upperBound)
    }

    // MARK: - Going

    func close(_ id: String) { remove(where: { $0.id == id }, how: .closed) }

    func clear(set: String) { remove(where: { $0.set == set }, how: .cleared) }

    func clear(ids: Set<String>) { remove(where: { ids.contains($0.id) }, how: .cleared) }

    func clearAll(_ how: UIHintDismissal = .cleared) { remove(where: { _ in true }, how: how) }

    /// The hints on a window whose screen changed, or that closed.
    func clear(window: Int, _ how: UIHintDismissal) { remove(where: { $0.window == window }, how: how) }

    /// Those whose time is up.
    func expire(now: Date = Date()) {
        let due = Set(deadlines.filter { $0.value <= now }.map(\.key))
        guard !due.isEmpty else { return }
        remove(where: { due.contains($0.id) }, how: .timedOut)
    }

    /// The person is reading it: its clock stops until they move off.
    func pause(_ id: String, now: Date = Date()) {
        guard let deadline = deadlines.removeValue(forKey: id) else { return }
        paused[id] = max(0, deadline.timeIntervalSince(now))
    }

    func resume(_ id: String, now: Date = Date()) {
        guard let left = paused.removeValue(forKey: id) else { return }
        deadlines[id] = now.addingTimeInterval(max(left, 1))
    }

    /// Frames as they are now; hints whose element has gone go too.
    func move(_ frames: [String: (frame: CGRect, window: Int)], gone: Set<String>) {
        for index in hints.indices {
            if let moved = frames[hints[index].id], moved.frame != hints[index].frame || moved.window != hints[index].window {
                hints[index].frame = moved.frame
                hints[index].window = moved.window
            }
        }
        if !gone.isEmpty { remove(where: { gone.contains($0.id) }, how: .elementGone) }
    }

    /// The earliest moment a hint is due, for the clock that calls `expire`.
    var nextDeadline: Date? { deadlines.values.min() }

    private func remove(where match: (UIHint) -> Bool, how: UIHintDismissal) {
        let going = hints.filter(match)
        guard !going.isEmpty else { return }
        let ids = Set(going.map(\.id))
        hints.removeAll { ids.contains($0.id) }
        for id in ids {
            deadlines[id] = nil
            paused[id] = nil
        }
        // A set is dismissed when its last hint goes.
        for set in Set(going.map(\.set)) where !hints.contains(where: { $0.set == set }) {
            sets[set] = nil
            dismissed.notify(Dismissed(set: set, how: how))
        }
    }
}
