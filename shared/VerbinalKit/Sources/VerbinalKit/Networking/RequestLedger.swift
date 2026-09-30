// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Every request the app sends to CADC and CANFAR, as it happens: which
/// service, who asked, how long it waited of its timeout, and how it ended.
/// In memory — the ones in flight and the last few hundred finished — so
/// "is CADC slow, or is this stuck?" has an answer (plan 23).
///
/// Only the meaning is kept: the service, times, the outcome and its codes.
/// No method, path, query, headers or body, so no password, token or ADQL
/// can reach it.
///
/// Requests are recorded where they are sent: `send(_:_:)` wraps the send,
/// so a request cannot be left unfinished (the `TaskHandle` rule).
/// `URLSession.recordedData(for:)` and `recordedDownload(for:)` are the
/// app's way to send; a source test fails on any other.
///
/// Shared by default (`shared`), as a cross-cutting log is; a test hands
/// in its own.
public final class RequestLedger: @unchecked Sendable {
    public static let shared = RequestLedger()

    /// One request.
    public struct Record: Codable, Sendable, Equatable, Identifiable {
        /// Unique across every ledger in the process.
        public let id: Int
        public let service: RequestService
        public let started: Date
        /// How long it may go without an answer.
        public let timeout: TimeInterval
        /// The person, an assistant, or the app.
        public let startedBy: Initiator
        public var finished: Date?
        public var outcome: RequestOutcome?
        /// The HTTP status, when there was an answer.
        public var status: Int?
        /// The `URLError` code, when there was none.
        public var errorCode: Int?

        public var isFinished: Bool { finished != nil }

        /// How long it took, or has been waiting.
        public func seconds(now: Date = Date()) -> TimeInterval {
            (finished ?? now).timeIntervalSince(started)
        }

        /// "HTTP 503", "URLError -1001", or nil.
        public var code: String? {
            if let status { return "HTTP \(status)" }
            if let errorCode { return "URLError \(errorCode)" }
            return nil
        }
    }

    /// What the ledger tells its observers.
    public enum Event: Sendable {
        case started(Record)
        case finished(Record)
        /// Its requests failed `failingAfter` times in a row, for reasons of
        /// its own (a timeout, no route, busy, a server error).
        case serviceFailing(RequestService, Record)
        /// It answered again after failing.
        case serviceRecovered(RequestService, Record)
    }

    /// What the app's own traffic says about a service.
    public struct ServiceStats: Sendable, Equatable {
        public let service: RequestService
        public let calls: Int
        public let failures: Int
        public let medianSeconds: Double?
        public let lastFailure: Record?
        public let lastAnswer: Date?
        public let isFailing: Bool
    }

    /// Failures in a row that mark a service as failing.
    public static let failingAfter = 3

    private let lock = NSLock()
    private let keep: Int
    private var inFlight: [Int: Record] = [:]
    private var finished: [Record] = []
    private var troubleInARow: [String: Int] = [:]
    private var failing: Set<String> = []
    private var observers: [UUID: @Sendable (Event) -> Void] = [:]

    private static let ids = IDCounter()

    /// `keep`: how many finished requests are remembered.
    public init(keep: Int = 300) {
        self.keep = keep
    }

    // MARK: - Recording

    /// Sends `request` with `send`, recording it from start to end — into
    /// this ledger and every `RequestTrace` above the caller.
    public func send<T>(
        _ request: URLRequest,
        _ send: (URLRequest) async throws -> (T, URLResponse)
    ) async throws -> (T, URLResponse) {
        let trace = RequestTrace.current
        let record = start(request)
        trace?.note(record)
        // Finished first, then noted: `trace?.note(finish(…))` would skip
        // the finish with no trace.
        do {
            let (value, response) = try await send(request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let done = finish(record.id, status.map(RequestOutcome.init(status:)) ?? .ok, status: status)
            trace?.note(done)
            return (value, response)
        } catch {
            let done = finish(record.id, RequestOutcome(error: error), errorCode: (error as? URLError)?.code.rawValue)
            trace?.note(done)
            throw error
        }
    }

    private func start(_ request: URLRequest) -> Record {
        let record = Record(id: Self.ids.next(), service: .of(request.url), started: Date(),
                            timeout: request.timeoutInterval, startedBy: Initiator.current)
        lock.withLock { inFlight[record.id] = record }
        notify(.started(record))
        return record
    }

    private func finish(_ id: Int, _ outcome: RequestOutcome, status: Int? = nil, errorCode: Int? = nil) -> Record {
        let (record, change) = lock.withLock { () -> (Record, Event?) in
            var record = inFlight.removeValue(forKey: id)!
            record.finished = Date()
            record.outcome = outcome
            record.status = status
            record.errorCode = errorCode
            finished.append(record)
            if finished.count > keep { finished.removeFirst(finished.count - keep) }
            return (record, serviceChange(after: record))
        }
        notify(.finished(record))
        if let change { notify(change) }
        return record
    }

    /// Whether `record` tips its service into failing, or out of it. A
    /// failure that is not the service's own (sign-in, a wrong request, a
    /// cancel, this Mac offline) neither counts nor clears.
    private func serviceChange(after record: Record) -> Event? {
        let id = record.service.id
        if record.outcome == .ok {
            troubleInARow[id] = 0
            return failing.remove(id) == nil ? nil : .serviceRecovered(record.service, record)
        }
        guard record.outcome?.isServiceTrouble == true else { return nil }
        troubleInARow[id, default: 0] += 1
        guard troubleInARow[id]! >= Self.failingAfter, failing.insert(id).inserted else { return nil }
        return .serviceFailing(record.service, record)
    }

    // MARK: - Reading

    /// Requests waiting for an answer, oldest first.
    public func waiting() -> [Record] {
        lock.withLock { inFlight.values.sorted { $0.id < $1.id } }
    }

    /// Finished requests, newest last.
    public func recent(_ limit: Int = .max) -> [Record] {
        lock.withLock { Array(finished.suffix(limit)) }
    }

    public func isFailing(_ serviceID: String) -> Bool {
        lock.withLock { failing.contains(serviceID) }
    }

    /// Services failing now.
    public func failingServices() -> [RequestService] {
        lock.withLock {
            let ids = failing
            var seen = Set<String>()
            return finished.reversed().map(\.service).filter { ids.contains($0.id) && seen.insert($0.id).inserted }
        }
    }

    /// Each service's traffic over the last `window` seconds.
    public func stats(within window: TimeInterval = 15 * 60, now: Date = Date()) -> [ServiceStats] {
        let (records, failingIDs) = lock.withLock { (finished.filter { now.timeIntervalSince($0.started) <= window }, failing) }
        return Dictionary(grouping: records, by: \.service.id).values.compactMap { calls in
            guard let service = calls.last?.service else { return nil }
            let seconds = calls.map { $0.seconds() }.sorted()
            return ServiceStats(
                service: service, calls: calls.count,
                failures: calls.filter { $0.outcome?.isFailure == true }.count,
                medianSeconds: seconds.isEmpty ? nil : seconds[seconds.count / 2],
                lastFailure: calls.last { $0.outcome?.isFailure == true },
                lastAnswer: calls.last { $0.outcome == .ok }?.finished,
                isFailing: failingIDs.contains(service.id))
        }
        .sorted { $0.service.id < $1.service.id }
    }

    // MARK: - Observing

    /// Calls `observer` with every event until `stopObserving`. It runs on
    /// the sender's thread: hand heavy work off.
    @discardableResult
    public func observe(_ observer: @escaping @Sendable (Event) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = observer }
        return id
    }

    public func stopObserving(_ id: UUID) {
        lock.withLock { observers[id] = nil }
    }

    private func notify(_ event: Event) {
        for observer in lock.withLock({ Array(observers.values) }) { observer(event) }
    }

    private final class IDCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }
}

/// The requests one piece of work made: a tool call, a task. Opened with
/// `run(_:)`; a request sent inside it — in any child task — is noted here
/// and in every trace above, so a call sees the requests of the task it
/// started. The ledger knows nothing of calls or tasks (orthogonality).
public final class RequestTrace: @unchecked Sendable {
    @TaskLocal public static var current: RequestTrace?

    public let parent: RequestTrace?
    private let lock = NSLock()
    private var byID: [Int: RequestLedger.Record] = [:]

    public init(parent: RequestTrace? = RequestTrace.current) {
        self.parent = parent
    }

    /// Runs `work` with this trace current.
    public func run<T>(_ work: () async throws -> T) async rethrows -> T {
        try await Self.$current.withValue(self) { try await work() }
    }

    func note(_ record: RequestLedger.Record) {
        lock.withLock { byID[record.id] = record }
        parent?.note(record)
    }

    /// Every request made inside it, in the order they started.
    public var records: [RequestLedger.Record] {
        lock.withLock { byID.values.sorted { $0.id < $1.id } }
    }

    /// Those still waiting for an answer.
    public var waiting: [RequestLedger.Record] {
        records.filter { !$0.isFinished }
    }
}

extension URLSession {
    /// `data(for:)`, recorded in `ledger`. The app sends this way, or
    /// through `NetworkClient`; nowhere else (a source test holds it).
    public func recordedData(for request: URLRequest, in ledger: RequestLedger = .shared) async throws -> (Data, URLResponse) {
        try await ledger.send(request) { try await self.data(for: $0) }
    }

    /// `download(for:)`, recorded in `ledger`.
    public func recordedDownload(for request: URLRequest, in ledger: RequestLedger = .shared) async throws -> (URL, URLResponse) {
        try await ledger.send(request) { try await self.download(for: $0) }
    }
}
