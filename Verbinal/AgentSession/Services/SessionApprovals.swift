// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// The person's say over assistant sessions (plan 25 S): an assistant asks
/// with `start_session`, the person allows it — with instructions for the
/// session — or declines, and until then the assistant's tools do not work
/// (M). The one owner of who is allowed, and on what terms.
@Observable
@MainActor
final class SessionApprovals {
    /// An assistant asking to start a session.
    struct Request: Identifiable, Equatable, Sendable {
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
    struct Approval: Equatable, Sendable {
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

    /// Asking now, oldest first: the window shows the first.
    private(set) var pending: [Request] = []
    private var waiting: [UUID: CheckedContinuation<Decision, Never>] = [:]
    private var allowed: [UUID: Approval] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - The instructions

    /// A session's instructions are at most this many words.
    static let maxWords = 250

    /// The instructions every window starts from, unless the person set their own.
    static let builtInInstructions = "Use only Verbinal and its tools for this work: no other apps, and no network connections outside Verbinal. Ask before anything destructive."

    private static let instructionsKey = "verbinal.agent.sessionInstructions"

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
        }
    }

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - Asking

    /// Whether `session` is allowed.
    func approval(for session: UUID) -> Approval? { allowed[session] }

    /// Asks the person — waiting as long as the assistant waits. If the
    /// assistant stops waiting, the request is withdrawn and the answer is
    /// `.abandoned`.
    func ask(_ request: Request) async -> Decision {
        if let approval = allowed[request.id] { return .allowed(approval) }
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
        let approval = Approval(request: request, instructions: text, allowedAt: Date())
        allowed[session] = approval
        resolve(session, .allowed(approval))
    }

    func decline(_ session: UUID) {
        resolve(session, .declined)
    }

    private func resolve(_ session: UUID, _ decision: Decision) {
        pending.removeAll { $0.id == session }
        waiting.removeValue(forKey: session)?.resume(returning: decision)
    }
}

/// The bridge's gate, answered by the approvals (plan 25 M).
struct SessionApprovalGate: AgentSessionGate {
    let approvals: SessionApprovals

    func isOpen(_ session: UUID) async -> Bool {
        await approvals.approval(for: session) != nil
    }
}
