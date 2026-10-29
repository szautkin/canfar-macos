// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// How an assistant's session is kept, wired once at launch.
extension AppState {
    /// The session log and Connected Assistants hear the same bridge (plan
    /// 52 C). No session, no tools: the person allows each one (plan 25), and
    /// a relay's reconnection continues its own (plan 34 S). A session ends
    /// when the person ends it, closes its connection, or turns AI agents off.
    func connectAgentSessions(to sessionLog: AppEventHub) {
        agentsService.sessionRecorder = AgentSessionRecorders([sessionLog, assistantConnections.recorder])
        let sessionGate = SessionApprovalGate(approvals: sessionApprovals)
        agentsService.sessionGate = sessionGate
        agentsService.sessionContinuity = sessionGate
        sessionApprovals.onEnded = { session, why, at in
            Task { await sessionLog.note(session, SessionLogLine.ended(why, at: at)) }
        }
        agentsService.onTurnedOff = { [weak self] in self?.sessionApprovals.endAll(.agentsTurnedOff) }
        assistantConnections.endSession = { [weak self] in self?.sessionApprovals.end($0, .closedByPerson) }
        assistantConnections.disconnect = { [weak self] session, reason in
            await self?.agentsService.closeConnection(serving: session, telling: reason)
        }
    }
}
