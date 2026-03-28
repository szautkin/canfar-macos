// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import AppKit

@Observable
@MainActor
final class SessionListModel {
    private let sessionService: SessionService

    var sessions: [Session] = []
    var isLoading = false
    var errorMessage = ""
    var hasError = false
    var isPolling = false
    var pollCountdown = 0

    private var pollTask: Task<Void, Never>?
    private let pollInterval = 15

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
            sessions = try await sessionService.getSessions()
            onSessionsRefreshed?()

            // Start or stop polling based on pending sessions
            if hasPendingSessions {
                startPolling()
            } else {
                stopPolling()
            }
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

    func getSessionEvents(id: String) async -> String? {
        try? await sessionService.getSessionEvents(id: id)
    }

    func getSessionLogs(id: String) async -> String? {
        try? await sessionService.getSessionLogs(id: id)
    }

    func openSessionInBrowser(_ session: Session) {
        guard session.isRunning, let url = URL(string: session.connectUrl) else { return }
        NSWorkspace.shared.open(url)
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
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stopPolling() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
        pollCountdown = 0
    }

    private func pollLoop() async {
        while !Task.isCancelled && isPolling {
            pollCountdown = pollInterval

            // Countdown
            for _ in 0..<pollInterval {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))
                pollCountdown -= 1
            }

            if Task.isCancelled { return }

            await loadSessions()

            if !hasPendingSessions {
                stopPolling()
                return
            }
        }
    }
}
