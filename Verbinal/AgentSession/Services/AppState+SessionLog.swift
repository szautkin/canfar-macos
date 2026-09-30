// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

extension AppState {
    /// A session's header: who connected to what, and the app's state then
    /// — the version and commit, macOS, the endpoints in use and which the
    /// person overrode, Auto-apply, the sign-in (plan 23 L2).
    func sessionLogHeader(_ session: UUID, _ client: String) -> SessionLogHeader {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let endpoints: [String: String] = [
            "login": self.endpoints.loginBaseURL, "skaha": self.endpoints.skahaBaseURL,
            "ac": self.endpoints.acBaseURL, "storage": self.endpoints.storageBaseURL,
            "registry": self.endpoints.registryBaseURL, "archive": self.endpoints.archiveBaseURL,
        ]
        return SessionLogHeader(
            session: session, client: client, opened: Date(), app: version,
            buildCommit: info?["VerbinalBuildCommit"] as? String,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            endpoints: endpoints,
            overridden: EndpointField.allCases.filter { endpointSettings.overrides[$0] != nil }.map(\.rawValue),
            autoApply: agentsService.autoApplyWrites, signedIn: isAuthenticated)
    }

    /// What is happening now: the app's live state, for a session's reader
    /// (plan 23 L3).
    func sessionNow() async -> SessionNow {
        let waiting = RequestLedger.shared.waiting()
        let running = tasks.tasks.filter { !$0.isFinished }
        let proposals = await agentsService.waitingProposals()
        return SessionNow(
            requestsWaiting: waiting.map {
                .init(service: $0.service.id, name: $0.service.name, seconds: $0.seconds(), timeout: $0.timeout,
                      startedBy: $0.startedBy.rawValue, line: $0.waitingSentence())
            },
            tasksRunning: running.map { task in
                .init(task: task.id, label: task.label, stage: task.stage.isEmpty ? nil : task.stage,
                      seconds: task.elapsed(), startedBy: task.startedBy.rawValue,
                      waitingOn: waiting.last { $0.cause.task == task.id }?.waitingSentence())
            },
            proposalsWaiting: proposals.map {
                .init(proposal: $0.proposal.id.uuidString, summary: $0.proposal.summary, why: $0.proposal.why, waits: $0.waits)
            },
            servicesFailing: RequestLedger.shared.failingServices().map(\.name),
            signedIn: isAuthenticated)
    }

    /// The session log's tools, when the log is kept (plan 23 L3, L4).
    func makeSessionLogTools() -> [any AITool] {
        guard let sessionLog else { return [] }
        let query = SessionLogQuery(store: sessionLog.store, hub: sessionLog)
        return [
            GetSessionLogTool(query: query, now: { [weak self] in await self?.sessionNow() ?? .quiet }),
            ExplainLogEntryTool(query: query),
            ListSessionLogsTool(query: query),
            ExportSessionLogTool(query: query),
            DeleteSessionLogsTool(query: query),
        ]
    }

    /// Their appliers: export at once under Auto-apply; delete after the person.
    func makeSessionLogAppliers(activity: AgentActivityStore) -> [any ProposalApplier] {
        guard let sessionLog else { return [] }
        let query = SessionLogQuery(store: sessionLog.store, hub: sessionLog)
        return [ExportSessionLogApplier(query: query, activity: activity),
                DeleteSessionLogsApplier(query: query, activity: activity)]
    }
}

extension SessionNow {
    /// Nothing happening — when the app is gone.
    static let quiet = SessionNow(requestsWaiting: [], tasksRunning: [], proposalsWaiting: [], servicesFailing: [], signedIn: false)
}
