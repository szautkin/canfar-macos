// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os
import VerbinalKit

/// One try at some work — a load, a render — so that its result is kept
/// only while it is the newest: a result that comes back after a newer try
/// began is dropped (plan 38). Numbered across the app, so two are never
/// the same.
struct Attempt: Hashable, Sendable {
    let number: Int
    let started: Date

    init(started: Date = Date()) {
        number = Self.counter.withLock { $0 += 1; return $0 }
        self.started = started
    }

    private static let counter = OSAllocatedUnfairLock(initialState: 0)
}

/// What went wrong, apart from when (plan 38): its kind, what the person
/// reads, and whether trying again can help.
struct Problem: Error, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case signInRequired, notFound, offline, refused, cancelled, other
    }

    let kind: Kind
    /// As the person reads it.
    let message: String
    /// Whether Try Again can help.
    var retry: Bool

    init(_ kind: Kind, _ message: String, retry: Bool = true) {
        self.kind = kind
        self.message = message
        self.retry = retry
    }

    /// The one reading of an error as a problem.
    init(_ error: any Error) {
        switch error {
        case let problem as Problem:
            self = problem
        case is CancellationError:
            self.init(.cancelled, String(localized: "Stopped."))
        case let network as NetworkError:
            switch network {
            case .unauthorized:
                self.init(.signInRequired, String(localized: "Sign in to CADC to see this."), retry: false)
            case .httpError(404, _):
                self.init(.notFound, String(localized: "Not found."), retry: false)
            case .httpError(let code, _) where code == 401 || code == 403:
                self.init(.refused, String(localized: "CADC refused it: you may not have access."), retry: false)
            default:
                self.init(.other, network.localizedDescription)
            }
        case let url as URLError:
            switch url.code {
            case .cancelled:
                self.init(.cancelled, String(localized: "Stopped."))
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                self.init(.offline, String(localized: "Verbinal cannot reach the network: \(url.localizedDescription)"))
            default:
                self.init(.other, url.localizedDescription)
            }
        default:
            self.init(.other, error.localizedDescription)
        }
    }
}

/// Anything fetched, loaded or computed (plan 38): not asked for yet, under
/// way, ready, or failed — one value, so a spinner and an error never show
/// at once and a stale result never lands. The last good value stays
/// through a refresh and a failure, so a list does not blank while it
/// reloads.
enum Phase<Value> {
    case idle
    case working(Attempt, last: Value?)
    case ready(Value)
    case failed(Problem, last: Value?)

    /// The value to show: the ready one, else the last good one.
    var value: Value? {
        switch self {
        case .idle: nil
        case .working(_, let last), .failed(_, let last): last
        case .ready(let value): value
        }
    }

    var isWorking: Bool { if case .working = self { true } else { false } }

    var problem: Problem? { if case .failed(let problem, _) = self { problem } else { nil } }

    /// The try under way, when there is one.
    var attempt: Attempt? { if case .working(let attempt, _) = self { attempt } else { nil } }

    /// Starts a new try, keeping what is shown; answers the try its
    /// result must bring back.
    mutating func begin() -> Attempt {
        let attempt = Attempt()
        self = .working(attempt, last: value)
        return attempt
    }

    /// The result of `attempt`: kept while it is the newest, else dropped
    /// (false). A cancelled try leaves what was there before it.
    @discardableResult
    mutating func finish(_ attempt: Attempt, with result: Result<Value, any Error>) -> Bool {
        guard case .working(let current, let last) = self, current == attempt else { return false }
        switch result {
        case .success(let value):
            self = .ready(value)
        case .failure(let error):
            let problem = Problem(error)
            if problem.kind == .cancelled {
                self = last.map(Phase.ready) ?? .idle
            } else {
                self = .failed(problem, last: last)
            }
        }
        return true
    }

    /// Something done with what is shown went wrong — a delete, a renew:
    /// the problem is said, and what was shown stays.
    mutating func fail(_ problem: Problem) {
        self = .failed(problem, last: value)
    }

    /// The person put the problem away: what was shown stays, without it.
    mutating func dismiss() {
        guard case .failed(_, let last) = self else { return }
        self = last.map(Phase.ready) ?? .idle
    }

    /// How a screen shows it: a spinner until there is something, the
    /// content (kept through a refresh or a failure), or the problem.
    func dataState(isEmpty: (Value) -> Bool) -> DataState {
        switch self {
        case .idle, .working(_, nil): .loading
        case .failed(_, nil): .error
        case .ready(let value), .working(_, let value?), .failed(_, let value?): isEmpty(value) ? .empty : .content
        }
    }

    /// Its state as an assistant reads it (plan 38): one word.
    var stateName: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}

extension Phase: Equatable where Value: Equatable {}
extension Phase: Sendable where Value: Sendable {}

/// A model that keeps `Phase`s: runs work as a try of one, keeping its
/// result only while it is the newest — the one way every load goes.
@MainActor
protocol PhaseOwner: AnyObject {}

extension PhaseOwner {
    /// Runs `work` as a new try of `phase`. Answers whether its result was
    /// kept (false when a newer try began meanwhile).
    @discardableResult
    func run<Value>(_ phase: ReferenceWritableKeyPath<Self, Phase<Value>>,
                    _ work: () async throws -> Value) async -> Bool {
        let attempt = self[keyPath: phase].begin()
        do {
            let value = try await work()
            return self[keyPath: phase].finish(attempt, with: .success(value))
        } catch {
            return self[keyPath: phase].finish(attempt, with: .failure(error))
        }
    }
}
