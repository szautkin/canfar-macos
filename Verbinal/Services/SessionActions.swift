// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What ends or extends a session on the platform.
protocol SessionEnding: Sendable {
    func deleteSession(id: String) async throws
    func renewSession(id: String) async throws
}

extension SessionService: SessionEnding {}

/// Deleting and renewing sessions, on the activity bar, whoever asks: the
/// Portal's buttons and an assistant's `delete_session`, `renew_session`
/// and `delete_sessions_bulk`. An assistant's went straight to the
/// platform and never reached the bar, so a trail such as "Delete session
/// xb0b7mu3" could not say whose it was (plan 17 A1).
@MainActor
final class SessionActions {
    private let service: any SessionEnding
    private let tasks: TaskRegistry

    init(service: any SessionEnding, tasks: TaskRegistry = .shared) {
        self.service = service
        self.tasks = tasks
    }

    func delete(id: String) async throws {
        try await tasks.track(.session, String(localized: "Delete session \(id)")) { [service] _ in
            try await service.deleteSession(id: id)
        }
    }

    func renew(id: String) async throws {
        try await tasks.track(.session, String(localized: "Renew session \(id)")) { [service] _ in
            try await service.renewSession(id: id)
        }
    }

    /// Deletes every one, whichever fail, as one task on the bar; returns
    /// the reason for each that failed, by id.
    func delete(ids: [String]) async -> [String: String] {
        let task = tasks.begin(.session, String(localized: "Delete \(ids.count) sessions"))
        let service = service
        let failed = await withTaskGroup(of: (String, String?).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        try await service.deleteSession(id: id)
                        return (id, nil)
                    } catch {
                        return (id, error.localizedDescription)
                    }
                }
            }
            var failed: [String: String] = [:]
            for await (id, reason) in group {
                if let reason { failed[id] = reason }
            }
            return failed
        }
        let deleted = ids.count - failed.count
        if failed.isEmpty {
            task.succeed(String(localized: "Deleted \(deleted) of \(ids.count)"))
        } else {
            let reasons = failed.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            task.fail(String(localized: "Deleted \(deleted) of \(ids.count) — \(reasons)"))
        }
        return failed
    }
}
