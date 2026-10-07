// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a tool call took, and what it means: its seconds, the requests it
/// made to CADC and CANFAR, and a verdict in one sentence with whether to
/// retry (plan 23). The reply's timing note and the session log's call
/// entry both say it, from here (DRY).
public struct CallTiming: Codable, Sendable, Equatable {
    public struct Request: Codable, Sendable, Equatable {
        /// `cadc-tap`.
        public let service: String
        /// "the CADC archive search".
        public let name: String
        public let seconds: Double
        public let timeout: Double
        /// `ok`, `timedOut`, … — or `waiting`, when the call ended first.
        public let outcome: String
        public let meaning: String
        /// "HTTP 503", "URLError -1001".
        public let code: String?
    }

    public let seconds: Double
    public let requests: [Request]
    /// "the CADC archive search did not answer in time — it is slow or
    /// down, after 120 s of its 120 s. Retry later."
    public let verdict: String
    /// Whether asking again can help; nil when nothing failed.
    public let retry: RequestOutcome.Retry?

    /// Slower than this, an answer is called slow.
    public static let slow: TimeInterval = 10

    /// Whether a reply carries its timing: it asked CADC or CANFAR, took 2 s
    /// or more, or failed. A quick local answer is left as it is.
    public static func isWorthNoting(_ traced: AIToolRouter.Traced) -> Bool {
        !traced.trace.records.isEmpty || traced.seconds >= 2 || traced.result.isFailure
    }

    /// The reply's second block: `{"timing": {...}}`, with the call's token
    /// in the session log for `explain_log_entry`.
    public struct Note: Encodable, Sendable {
        public struct Body: Encodable, Sendable {
            public let seconds: Double
            public let requests: [Request]
            public let verdict: String
            public let retry: RequestOutcome.Retry?
            /// The call's entry in the session log.
            public let logToken: Int?
            /// The session it belongs to (plan 25).
            public let session: String?
        }
        public let timing: Body

        public init(_ timing: CallTiming, logToken: Int?, session: UUID? = nil) {
            self.timing = Body(seconds: (timing.seconds * 10).rounded() / 10, requests: timing.requests,
                               verdict: timing.verdict, retry: timing.retry, logToken: logToken,
                               session: session?.uuidString)
        }

        public var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }

    public init(_ traced: AIToolRouter.Traced, now: Date = Date()) {
        seconds = traced.seconds
        let records = traced.trace.records
        requests = records.map { record in
            let outcome = record.outcome
            return Request(service: record.service.id, name: record.service.name,
                           seconds: record.seconds(now: now), timeout: record.timeout,
                           outcome: outcome?.rawValue ?? "waiting",
                           meaning: outcome?.meaning ?? "had not answered", code: record.code)
        }
        (verdict, retry) = Self.judge(records, failed: traced.result.isFailure, seconds: traced.seconds, now: now)
    }

    /// The verdict: what each service's last request came to.
    static func judge(_ records: [RequestLedger.Record], failed: Bool, seconds: Double,
                      now: Date) -> (String, RequestOutcome.Retry?) {
        func time(_ s: Double) -> String { Self.duration(s) }
        // A service asked again that then answered is judged by its answer.
        var last: [String: RequestLedger.Record] = [:]
        for record in records { last[record.service.id] = record }
        let lasts = last.values.sorted { $0.id < $1.id }
        let unanswered = lasts.filter { !$0.isFinished || $0.outcome == .cancelled }
        let failures = lasts.filter { $0.outcome?.isFailure == true && $0.outcome != .cancelled }
        // A call that answered handled what its requests met — a 404 that
        // means "not there yet", a listing still on its way: said, with no
        // advice to ask again (handout 31: "change the request" for a
        // result not written yet).
        if !failed {
            let along = failures.map { "\($0.service.name) \($0.outcome?.meaning ?? "")\($0.code.map { " (\($0))" } ?? "")" }
                + unanswered.map { "\($0.service.name) was still being asked" }
            if !along.isEmpty {
                return ("It answered in \(time(seconds)); on the way, \(along.joined(separator: "; ")).", nil)
            }
        }
        if let failure = failures.last, let outcome = failure.outcome, let retry = outcome.retry {
            let others = failures.dropLast().map { "\($0.service.name) \($0.outcome?.meaning ?? "")" }
            let also = others.isEmpty ? "" : "; also " + others.joined(separator: "; ")
            let code = failure.code.map { " (\($0))" } ?? ""
            return ("\(failure.service.name) \(outcome.meaning), after \(time(failure.seconds(now: now))) of its \(Int(failure.timeout)) s\(code)\(also). \(retry.advice.prefix(1).uppercased() + retry.advice.dropFirst()).", retry)
        }
        if let waiting = unanswered.last {
            return ("\(waiting.service.name) had not answered after \(time(waiting.seconds(now: now))) of its \(Int(waiting.timeout)) s: it is slow, not failed. Retry later, or read get_session_log.", .later)
        }
        if let slowest = lasts.max(by: { $0.seconds(now: now) < $1.seconds(now: now) }) {
            let s = slowest.seconds(now: now)
            let others = lasts.count > 1 ? " (of \(lasts.count) services asked)" : ""
            let verdict = s >= slow
                ? "\(slowest.service.name) answered in \(time(s)): slow, but it answered\(others)."
                : "\(slowest.service.name) answered in \(time(s))\(others)."
            return (failed ? verdict + " The call failed after it, inside Verbinal." : verdict, nil)
        }
        if failed { return ("It failed inside Verbinal, without asking CADC or CANFAR.", nil) }
        return (seconds >= 2 ? "It took \(time(seconds)) inside Verbinal, without asking CADC or CANFAR." : "It answered at once.", nil)
    }

    /// "0.4 s", "48 s", "3 min 5 s", "1 h 2 min".
    public static func duration(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}

extension ToolResult {
    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
