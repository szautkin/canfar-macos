// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A decision the app took about someone's work, with its rule in words:
/// "applied at once: Auto-apply is on and this is not a delete" (plan 23 A).
public struct Decision: Codable, Sendable, Equatable {
    public enum Rule: String, Codable, Sendable, CaseIterable {
        /// A change applied without the person: Auto-apply.
        case appliedAtOnce
        /// A change held in Pending for the person.
        case heldForPerson
        /// A request asked again after a failure.
        case retried
        /// A request not asked again.
        case notRetried
        /// A deadline reached: the app stopped waiting.
        case stoppedWaiting
        /// The sign-in renewed without the person.
        case signedInAgain
        /// The stored sign-in kept, unchecked: CADC could not be reached.
        case signInKept
        /// The sign-in could not be renewed, and why.
        case signInLost
    }

    public let rule: Rule
    /// What was decided and why: "search_observations stopped waiting
    /// after 130 s; the CADC archive search had not answered in 120 s".
    public let sentence: String
    public let at: Date
    public let startedBy: Initiator
    public let cause: Cause
}

/// Where the app's decisions are recorded, by the policy that takes each —
/// auto-apply, retries, deadlines, the sign-in — for the session log to
/// hear. Keeps no history of its own. Shared by default; a test hands in
/// its own.
public final class DecisionLog: Sendable {
    public static let shared = DecisionLog()

    public let observers = Observers<Decision>()

    public init() {}

    /// Records `rule`'s decision, said as `sentence`, under the work's cause.
    public func record(_ rule: Decision.Rule, _ sentence: String, cause: Cause = Cause.current) {
        observers.notify(Decision(rule: rule, sentence: sentence, at: Date(), startedBy: Initiator.current, cause: cause))
    }
}

extension DecisionLog {
    /// A deadline reached: records that `label` stopped waiting after
    /// `seconds`, and answers what was still in flight, in words — "the
    /// CADC archive search had waited 60 s of its 120 s and had not
    /// answered", or that no request was waiting — for the caller's error.
    /// Empty when the work opened no trace, so nothing can be said.
    public func deadlineReached(_ label: String, after seconds: TimeInterval) -> String {
        let detail: String
        if let trace = RequestTrace.current {
            let waiting = trace.waiting
            detail = waiting.isEmpty
                ? "no request to CADC or CANFAR was waiting: the time went inside Verbinal"
                : waiting.map { $0.waitingSentence() + " and had not answered" }.joined(separator: "; ")
        } else {
            detail = ""
        }
        record(.stoppedWaiting, "\(label) stopped waiting after \(Int(seconds)) s" + (detail.isEmpty ? "" : "; \(detail)"))
        return detail
    }
}
