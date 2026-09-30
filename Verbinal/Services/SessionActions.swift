// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What ends or extends a session on the platform, and what it lists.
protocol SessionEnding: Sendable {
    func deleteSession(id: String) async throws
    func renewSession(id: String) async throws
    func allSessionIDs() async throws -> Set<String>
}

/// A session id the platform does not list. CANFAR answers a DELETE of one
/// with success, so a typo or a stale id read as deleted (QA N20).
struct NoSuchSession: LocalizedError, Equatable {
    let id: String
    var errorDescription: String? { String(localized: "no such session \(id) — the platform lists none by that id") }
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
            guard try await service.allSessionIDs().contains(id) else { throw NoSuchSession(id: id) }
            try await service.deleteSession(id: id)
        }
    }

    func renew(id: String) async throws {
        try await tasks.track(.session, String(localized: "Renew session \(id)")) { [service] _ in
            try await service.renewSession(id: id)
        }
    }

    /// Deletes every one the platform lists, whichever fail, as one task on
    /// the bar; returns the reason for each that failed, by id — an id the
    /// platform does not list among them, never sent.
    func delete(ids: [String]) async -> [String: String] {
        let task = tasks.begin(.session, String(localized: "Delete \(ids.count) sessions"))
        let service = service
        let listed: Set<String>
        do {
            listed = try await service.allSessionIDs()
        } catch {
            task.fail(error.localizedDescription)
            return Dictionary(ids.map { ($0, error.localizedDescription) }, uniquingKeysWith: { first, _ in first })
        }
        let unknown = ids.filter { !listed.contains($0) }
        // Each delete is recorded where it is made, as this task's (plan 23 C).
        let failed = await task.within { await withTaskGroup(of: (String, String?).self) { group in
            for id in ids where listed.contains(id) {
                group.addTask {
                    do {
                        try await service.deleteSession(id: id)
                        return (id, nil)
                    } catch {
                        return (id, error.localizedDescription)
                    }
                }
            }
            var failed = Dictionary(unknown.map { ($0, NoSuchSession(id: $0).localizedDescription) }, uniquingKeysWith: { first, _ in first })
            for await (id, reason) in group {
                if let reason { failed[id] = reason }
            }
            return failed
        } }
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
