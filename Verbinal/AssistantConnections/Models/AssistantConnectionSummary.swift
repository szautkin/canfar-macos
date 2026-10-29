// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a Connected Assistants row says (plan 52 C1, C5): who, its session,
/// its bridge, its calls, and what deserves a look. Made from the
/// connection and its session, without a window, so the words are tested.
struct AssistantConnectionSummary: Equatable {
    enum Mark: Equatable {
        /// Its bridge is from a Verbinal older than 1.4.2, which cannot be
        /// told to end: only quitting its app (named) ends it.
        case cannotBeClosed(app: String)
        /// Its bridge runs from another Verbinal: this version.
        case anotherVerbinal(String)
        /// Its session ended while its bridge stays connected; Close ends the bridge.
        case sessionEnded
    }

    let title: String
    let session: String
    let bridge: String?
    let calls: String
    let marks: [Mark]
    /// Whether Close still does something: it ends the session, the bridge,
    /// or both. An older bridge whose session has ended goes only when its
    /// app quits.
    let canClose: Bool

    init(_ connection: AssistantConnection, session state: SessionApprovals.SessionState,
         asking: SessionApprovals.Request?, appVersion: String, now: Date) {
        let request: SessionApprovals.Request? = switch state {
        case .active(let approval): approval.request
        default: asking
        }
        title = request.map(Self.presented) ?? connection.client.replacingOccurrences(of: "/", with: " ")
        session = Self.sessionText(state)
        bridge = connection.relay.map { relay in
            let parent = relay.parentName.map { "\($0) (\(relay.parentPID))" } ?? "\(relay.parentPID)"
            return String(localized: "Bridge \(String(relay.pid)), launched by \(parent), from Verbinal \(relay.version)")
        }
        calls = connection.lastCall.map { last in
            let relative = RelativeDateTimeFormatter()
            relative.dateTimeStyle = .named   // "now", not "in 0 seconds"
            let ago = relative.localizedString(for: last, relativeTo: now)
            return String(localized: "Calls: \(connection.calls), the last \(ago)")
        } ?? String(localized: "No call yet")
        let ended = if case .ended = state { true } else { false }
        var marks: [Mark] = []
        if let relay = connection.relay {
            if relay.version != appVersion { marks.append(.anotherVerbinal(relay.version)) }
            if ended { marks.append(.sessionEnded) }
        } else {
            marks.append(.cannotBeClosed(app: connection.clientName))
        }
        self.marks = marks
        canClose = connection.relay != nil || !ended
    }

    /// "Claude Code (claude-opus-5-5)", as the assistant presents itself.
    private static func presented(_ request: SessionApprovals.Request) -> String {
        request.model.map { "\(request.agent) (\($0))" } ?? request.agent
    }

    private static func sessionText(_ state: SessionApprovals.SessionState) -> String {
        switch state {
        case .none: String(localized: "No session yet")
        case .asking: String(localized: "Asking you to start a session")
        case .active(let approval):
            approval.request.purpose.map { String(localized: "Session allowed: \($0)") } ?? String(localized: "Session allowed")
        case .ended(let why):
            switch why {
            case .idle: String(localized: "Session ended: no call for the idle time")
            case .byPerson: String(localized: "Session ended by you")
            case .agentsTurnedOff: String(localized: "Session ended when AI agents were turned off")
            case .closedByPerson: String(localized: "Session ended: you closed its connection")
            }
        }
    }
}

extension AssistantConnectionSummary.Mark {
    /// What the person reads, and can do, about it.
    var text: String {
        switch self {
        case .cannotBeClosed(let app):
            String(localized: "Its bridge is from a Verbinal older than 1.4.2, which can't be closed from here: quit the assistant's app (\(app)) to end it.")
        case .anotherVerbinal(let version):
            String(localized: "Its bridge runs from Verbinal \(version). Quit and reopen the assistant's app to use this one.")
        case .sessionEnded:
            String(localized: "Its session has ended, but its bridge is still connected. Close ends it.")
        }
    }
}
