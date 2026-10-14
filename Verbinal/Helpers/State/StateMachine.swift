// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os

/// One concern's states and what moves it between them (plan 38): a pure
/// function, tested as a table — the effects (a download, a render) stay
/// in the model, which sends an event when one ends.
protocol StateMachine {
    associatedtype State: Equatable & Sendable
    associatedtype Event: Sendable

    /// The state after `event`; nil when the event means nothing in `state`.
    static func next(_ state: State, on event: Event) -> State?
}

/// A machine's state, for SwiftUI to watch and an assistant's tool to wait
/// on (plan 38). An event that means nothing where it is, is refused —
/// logged, never a crash, and the state stays.
@Observable
@MainActor
final class Machine<M: StateMachine> {
    private(set) var state: M.State
    /// Events refused so far, for a test or a diagnosis to read.
    @ObservationIgnored private(set) var refusals = 0

    @ObservationIgnored private var waiters: [UUID: Waiter] = [:]
    private struct Waiter {
        let wanted: (M.State) -> Bool
        let resume: (M.State) -> Void
    }

    private static var logger: Logger { Logger(subsystem: "com.codebg.Verbinal", category: "StateMachine") }

    init(_ initial: M.State) {
        state = initial
    }

    /// Moves the machine on `event`; false when it is refused.
    @discardableResult
    func send(_ event: M.Event) -> Bool {
        guard let next = M.next(state, on: event) else {
            refusals += 1
            Self.logger.notice("\(String(describing: M.self), privacy: .public) refused \(String(describing: event), privacy: .public) in \(String(describing: self.state), privacy: .public)")
            return false
        }
        if next != state { state = next }
        for (id, waiter) in waiters where waiter.wanted(state) {
            waiters[id] = nil
            waiter.resume(state)
        }
        return true
    }

    /// The state once it is one `wanted` says, or as it is after `timeout`
    /// — what an assistant's tool waits on, instead of polling.
    func until(_ wanted: @escaping (M.State) -> Bool, timeout: Duration) async -> M.State {
        if wanted(state) { return state }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(wanted: wanted, resume: { continuation.resume(returning: $0) })
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                waiter.resume(self.state)
            }
        }
    }
}
