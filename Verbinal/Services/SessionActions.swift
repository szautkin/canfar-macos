// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What ends or extends a session on the platform, and what it lists.
protocol SessionEnding: Sendable {
    /// Ends the session, whatever its type: a desktop's apps go with it.
    func deleteSession(id: String) async throws
    /// Stops one desktop app, listed under its desktop's session id.
    func deleteDesktopApp(session: String, app: String) async throws
    func renewSession(id: String) async throws
    /// Everything the platform lists, of every type.
    func listing() async throws -> [ListedSession]
}

extension SessionEnding {
    func allSessionIDs() async throws -> Set<String> { Set(try await listing().map(\.id)) }
}

/// One entry of the platform's session listing: a session, or a desktop app
/// listed under its desktop's id with its own `appid` (Skaha's
/// `canfar.net/id` and `canfar.net/app-id` labels).
struct ListedSession: Decodable, Sendable, Equatable {
    let id: String
    let type: String
    var status: String?
    var name: String?
    var image: String?
    var appid: String?

    var isDesktopApp: Bool { type.lowercased() == "desktop-app" }
    /// Going already: the delete took.
    var isEnding: Bool { status?.lowercased() == "terminating" }
}

/// A delete CANFAR answered but did not make: Skaha answers a delete it
/// could not make as it does one it made, so the listing is asked after.
struct SessionStillRunning: LocalizedError, Equatable {
    let what: String
    let status: String
    var errorDescription: String? {
        String(localized: "CANFAR accepted the delete of \(what), but it is still \(status). Try again, or end it on the Science Portal.")
    }
}

struct NoSuchDesktopApp: LocalizedError, Equatable {
    let session: String
    let app: String
    var errorDescription: String? {
        String(localized: "no desktop app \(app) in session \(session) — list_sessions lists each desktop's apps")
    }
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

    /// Ends session `id`, whatever its type — a desktop's apps with it — or,
    /// given `app`, only that desktop app.
    func delete(id: String, app: String? = nil) async throws {
        let label = app.map { String(localized: "Stop desktop app \($0) of session \(id)") }
            ?? String(localized: "Delete session \(id)")
        try await tasks.track(.session, label) { [service] _ in
            let listed = try await service.listing().filter { $0.id == id }
            guard !listed.isEmpty else { throw NoSuchSession(id: id) }
            if let app {
                guard listed.contains(where: { $0.appid == app }) else { throw NoSuchDesktopApp(session: id, app: app) }
                try await service.deleteDesktopApp(session: id, app: app)
            } else {
                try await service.deleteSession(id: id)
            }
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
