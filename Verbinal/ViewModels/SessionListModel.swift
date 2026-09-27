// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

@Observable
@MainActor
final class SessionListModel: CadencedPoller {
    private let sessionService: SessionService

    var sessions: [Session] = []
    var isLoading = false
    var errorMessage = ""
    var hasError = false
    var isPolling = false
    var pollCountdown = 0

    private var pollTask: Task<Void, Never>?
    private(set) var cadence = PollCadence(watchCeiling: PollCadence.sessionWatchSeconds)
    /// Status by session id at the last load; nil before the first.
    private var previousStatuses: [String: String]?

    /// Fires when sessions are refreshed (for updating session counters).
    var onSessionsRefreshed: (() -> Void)?

    init(sessionService: SessionService) {
        self.sessionService = sessionService
    }

    func loadSessions() async {
        isLoading = true
        hasError = false
        errorMessage = ""

        do {
            let fetched = try await sessionService.getSessions()
            let transitions = StatusTransitions(
                previous: previousStatuses,
                current: Dictionary(fetched.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last }))
            for session in transitions.newlySettled(
                fetched, id: \.id,
                wasInFlight: { $0.lowercased() == "pending" },
                isSettled: { $0.isRunning || $0.isFailed }) {
                if session.isRunning {
                    NotificationService.sendSessionReady(sessionName: session.sessionName, image: session.containerImage)
                } else {
                    NotificationService.sendSessionFailed(sessionName: session.sessionName, image: session.containerImage)
                }
            }
            previousStatuses = transitions.current
            sessions = fetched
            onSessionsRefreshed?()

            // Keep watching: quickly while a session is pending, at the idle
            // interval otherwise (a session can start from another machine).
            cadence.observe(inFlight: hasPendingSessions, changed: transitions.changed)
            startPolling()
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func deleteSession(id: String) async {
        do {
            try await sessionService.deleteSession(id: id)
            // Grace period for backend state synchronization (matches Linux client)
            try? await Task.sleep(for: .seconds(3))
            await loadSessions()
        } catch {
            hasError = true
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func renewSession(id: String) async {
        do {
            try await sessionService.renewSession(id: id)
            await loadSessions()
        } catch {
            hasError = true
            errorMessage = "Renew failed: \(error.localizedDescription)"
        }
    }

    /// Fetches session events. Returns `.failure` (with the underlying error)
    /// instead of swallowing it, so callers can distinguish a real fetch
    /// failure (auth/network/missing endpoint) from a successful empty result.
    func getSessionEvents(id: String) async -> Result<String, Error> {
        do {
            return .success(try await sessionService.getSessionEvents(id: id))
        } catch {
            return .failure(error)
        }
    }

    /// Fetches session logs. See `getSessionEvents` for failure semantics.
    func getSessionLogs(id: String) async -> Result<String, Error> {
        do {
            return .success(try await sessionService.getSessionLogs(id: id))
        } catch {
            return .failure(error)
        }
    }

    func connectURL(for session: Session) -> URL? {
        guard session.isRunning else { return nil }
        return URL(string: session.connectUrl)
    }

    var hasPendingSessions: Bool {
        sessions.contains { $0.isPending }
    }

    func sessionCount(forType type: String) -> Int {
        sessions.filter { $0.sessionType.lowercased() == type.lowercased() }.count
    }

    // MARK: - Polling

    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        pollTask = startPollLoop()
    }

    func stopPolling() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
        pollCountdown = 0
    }

    func poll() async {
        await loadSessions()
    }
}
