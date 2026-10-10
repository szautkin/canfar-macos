// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

/// The person's say over assistant sessions (plan 25 S): an assistant asks
/// with `start_session`, the person allows it — with instructions for the
/// session — or declines, and until then the assistant's tools do not work
/// (M). The one owner of who is allowed, and on what terms.
///
/// A session is its relay's (plan 34 S): the relay an assistant launched
/// keeps its session across Verbinal's restarts, so the person is not asked
/// again for an assistant they allowed. An allowed session ends after the
/// idle time the person sets, when they end it, or when they turn external
/// AI agents off; the same session can then be allowed again.
@Observable
@MainActor
final class SessionApprovals {
    /// An assistant asking to start a session.
    struct Request: Identifiable, Equatable, Sendable, Codable {
        /// The session: the connection's.
        let id: UUID
        /// As the connection names the client: `claude-code/2.1`.
        let client: String
        let mcpVersion: String?
        /// As the assistant presents itself — its own words, unchecked.
        let agent: String
        let model: String?
        let purpose: String?
        let askedAt: Date
    }

    /// A session the person allowed.
    struct Approval: Equatable, Sendable, Codable {
        let request: Request
        /// The person's instructions for the session, word for word.
        let instructions: String
        let allowedAt: Date
    }

    enum Decision: Equatable, Sendable {
        case allowed(Approval)
        case declined
        /// The assistant stopped waiting before the person answered.
        case abandoned
    }

    /// Why an allowed session ended (plan 34 S).
    enum Ending: String, Codable, Sendable {
        /// No call for the idle time.
        case idle
        /// The person ended it, in Session Logs.
        case byPerson
        /// The person turned external AI agents off.
        case agentsTurnedOff
    }

    /// A relay's session, kept across launches.
    struct Kept: Codable, Equatable, Sendable {
        let session: UUID
        /// The relay's fingerprint (`AgentSession.relayFingerprint`), never its secret.
        var relay: String?
        /// The person's answer, while it holds.
        var approval: Approval?
        var lastUsed: Date
        var ended: Ending?
        var endedAt: Date?
    }

    /// Asking now, oldest first: the window shows the first.
    private(set) var pending: [Request] = []
    /// The sessions allowed now, for **End Session**.
    private(set) var allowedSessions: Set<UUID> = []
    /// Told when an allowed session ends, with when: the session's log says so.
    var onEnded: ((_ session: UUID, _ why: Ending, _ at: Date) -> Void)?

    private var waiting: [UUID: CheckedContinuation<Decision, Never>] = [:]
    private var kept: [UUID: Kept] = [:]
    /// Relays whose session has not been allowed yet: forgotten at quit.
    private var relays: [String: UUID] = [:]
    private let defaults: UserDefaults
    private let file: URL?
    private let now: () -> Date
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "SessionApprovals")

    /// Where the production app keeps them, beside the session logs.
    static var productionFile: URL {
        SessionLogStore.productionDirectory.appendingPathComponent("approvals.json")
    }

    /// `file` nil keeps them in memory only, as tests do.
    init(defaults: UserDefaults = .standard, file: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.file = file
        self.now = now
        let minutes = defaults.integer(forKey: Self.idleKey)
        self.idleMinutes = Self.idleChoices.contains(minutes) ? minutes : Self.defaultIdleMinutes
        self.instructionsChangedAt = defaults.object(forKey: Self.instructionsChangedKey) as? Date
        load()
    }

    // MARK: - The instructions

    /// A session's instructions are at most this many words.
    static let maxWords = 250

    /// The instructions every window starts from, unless the person set their own.
    static let builtInInstructions = "Use only Verbinal and its tools for this work: no other apps, and no network connections outside Verbinal. Ask before anything destructive."

    private static let instructionsKey = "verbinal.agent.sessionInstructions"
    private static let instructionsChangedKey = "verbinal.agent.sessionInstructionsChangedAt"

    /// When the person last set their default instructions; nil before
    /// they ever did (plan 36 3.4: the newer of two devices' wins).
    private(set) var instructionsChangedAt: Date?

    /// Whether the person set instructions of their own.
    var hasOwnInstructions: Bool { defaults.string(forKey: Self.instructionsKey) != nil }

    /// The person's default instructions, as set in Settings ▸ AI Agent.
    var defaultInstructions: String {
        get { defaults.string(forKey: Self.instructionsKey) ?? Self.builtInInstructions }
        set {
            let text = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text == Self.builtInInstructions {
                defaults.removeObject(forKey: Self.instructionsKey)
            } else {
                defaults.set(text, forKey: Self.instructionsKey)
            }
            instructionsChangedAt = now()
            defaults.set(instructionsChangedAt, forKey: Self.instructionsChangedKey)
        }
    }

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - The idle time (plan 34 S)

    /// The choices of Settings ▸ AI Agent ▸ End an idle session after, in minutes.
    static let idleChoices = [15, 60, 240, 720, 1440]
    static let defaultIdleMinutes = 60
    private static let idleKey = "verbinal.agent.sessionIdleMinutes"

    /// An allowed session ends after this many minutes without a call. The person's.
    var idleMinutes: Int {
        didSet {
            guard idleMinutes != oldValue else { return }
            if idleMinutes == Self.defaultIdleMinutes {
                defaults.removeObject(forKey: Self.idleKey)
            } else {
                defaults.set(idleMinutes, forKey: Self.idleKey)
            }
        }
    }

    /// "1 hour": as an assistant is told it.
    nonisolated static func idleText(_ minutes: Int) -> String {
        switch minutes {
        case let m where m % 1440 == 0: m == 1440 ? "1 day" : "\(m / 1440) days"
        case let m where m % 60 == 0: m == 60 ? "1 hour" : "\(m / 60) hours"
        default: "\(minutes) minutes"
        }
    }

    // MARK: - Asking

    /// Whether `session` is allowed. One idle past the time ends here.
    func approval(for session: UUID) -> Approval? {
        guard let entry = kept[session], let approval = entry.approval else { return nil }
        let idleSince = entry.lastUsed.addingTimeInterval(TimeInterval(idleMinutes * 60))
        if now() > idleSince {
            end(session, .idle, at: idleSince)
            return nil
        }
        return approval
    }

    /// A call of `session`'s: whether it is allowed. A call keeps it alive.
    func use(_ session: UUID) -> Bool {
        guard approval(for: session) != nil, let before = kept[session]?.lastUsed else { return false }
        let time = now()
        kept[session]?.lastUsed = time
        // Kept on disk to the minute: often enough for an idle time of 15.
        if time.timeIntervalSince(before) > 60 { save() }
        return true
    }

    /// Why `session`, once allowed, is not now; nil when it never was.
    func endedBecause(_ session: UUID) -> String? {
        guard approval(for: session) == nil, let ending = kept[session]?.ended else { return nil }
        switch ending {
        case .idle: return "Your session ended after \(Self.idleText(idleMinutes)) without a call."
        case .byPerson: return "The person ended your session in Verbinal."
        case .agentsTurnedOff: return "Your session ended when the person turned off external AI agents."
        }
    }

    /// The session the relay of `fingerprint` had, allowed or not; `fresh`,
    /// now the relay's, when it had none.
    func session(forRelay fingerprint: String, fresh: UUID) -> UUID {
        if let known = kept.values.first(where: { $0.relay == fingerprint })?.session ?? relays[fingerprint] {
            return known
        }
        relays[fingerprint] = fresh
        return fresh
    }

    /// Asks the person — waiting as long as the assistant waits. If the
    /// assistant stops waiting, the request is withdrawn and the answer is
    /// `.abandoned`. An allowed session is answered at once.
    func ask(_ request: Request) async -> Decision {
        if use(request.id), let approval = kept[request.id]?.approval { return .allowed(approval) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // A second ask for the same session waits on the same answer.
                if let earlier = waiting[request.id] { earlier.resume(returning: .abandoned) }
                waiting[request.id] = continuation
                if !pending.contains(where: { $0.id == request.id }) { pending.append(request) }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(request.id, .abandoned) }
        }
    }

    /// The person's answer.
    func allow(_ session: UUID, instructions: String) {
        guard let request = pending.first(where: { $0.id == session }) else { return }
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = now()
        let approval = Approval(request: request, instructions: text, allowedAt: time)
        let relay = kept[session]?.relay ?? relays.first(where: { $0.value == session })?.key
        relays = relays.filter { $0.value != session }
        kept[session] = Kept(session: session, relay: relay, approval: approval, lastUsed: time)
        allowedSessions.insert(session)
        save()
        resolve(session, .allowed(approval))
    }

    func decline(_ session: UUID) {
        resolve(session, .declined)
    }

    /// Every request waiting: nobody is there to allow them — the app's
    /// window closed.
    func declineAll() {
        pending.map(\.id).forEach(decline)
    }

    private func resolve(_ session: UUID, _ decision: Decision) {
        pending.removeAll { $0.id == session }
        waiting.removeValue(forKey: session)?.resume(returning: decision)
    }

    // MARK: - Ending

    /// Ends an allowed session: its next call is refused, saying why, and
    /// `start_session` asks the person again.
    func end(_ session: UUID, _ why: Ending, at time: Date? = nil) {
        guard kept[session]?.approval != nil else { return }
        let at = time ?? now()
        kept[session]?.approval = nil
        kept[session]?.ended = why
        kept[session]?.endedAt = at
        allowedSessions.remove(session)
        save()
        onEnded?(session, why, at)
    }

    /// Ends every allowed session.
    func endAll(_ why: Ending) {
        for session in allowedSessions { end(session, why) }
    }

    // MARK: - Keeping

    /// A relay's session is kept a day past its end, or its last call: long
    /// enough for a restart, not for ever.
    private static let keptFor: TimeInterval = 24 * 3600

    private func load() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([Kept].self, from: data) else {
            Self.logger.error("approvals.json unreadable; starting with none")
            return
        }
        let time = now()
        for entry in list where time.timeIntervalSince(entry.endedAt ?? entry.lastUsed) < Self.keptFor {
            kept[entry.session] = entry
            if entry.approval != nil { allowedSessions.insert(entry.session) }
        }
    }

    private func save() {
        guard let file else { return }
        let time = now()
        let list = kept.values
            .filter { time.timeIntervalSince($0.endedAt ?? $0.lastUsed) < Self.keptFor }
            .sorted { $0.lastUsed < $1.lastUsed }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(list).write(to: file, options: .atomic)
        } catch {
            Self.logger.error("approvals.json not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The bridge's gate and continuity, answered by the approvals (plan 25 M,
/// plan 34 S).
struct SessionApprovalGate: AgentSessionGate, AgentSessionContinuity {
    let approvals: SessionApprovals

    func isOpen(_ session: UUID) async -> Bool {
        await approvals.use(session)
    }

    func endedBecause(_ session: UUID) async -> String? {
        await approvals.endedBecause(session)
    }

    func session(forRelay fingerprint: String, fresh: UUID) async -> UUID {
        await approvals.session(forRelay: fingerprint, fresh: fresh)
    }
}
