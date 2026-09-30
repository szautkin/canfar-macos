// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// One open session's log: its entries in order, each given its token and
/// written to its file as it happens (plan 23 L2). Past its 2 MB, the
/// oldest calls, requests, tasks and app entries go first, changes and
/// decisions last, and the log says how many went.
actor SessionJournal {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "SessionLog")

    let header: SessionLogHeader
    private let store: SessionLogStore
    private let url: URL?
    private let maxBytes: Int
    private(set) var entries: [SessionLogEntry] = []
    private var nextToken = 1
    private var bytes = 0
    /// Calls under way: a request of theirs is told in the call's entry.
    private var callsInFlight: Set<UUID> = []
    private(set) var isClosed = false

    nonisolated var session: UUID { header.session }

    init(header: SessionLogHeader, store: SessionLogStore, maxBytes: Int = SessionLogRetention.maxSessionBytes) {
        self.header = header
        self.store = store
        self.maxBytes = maxBytes
        do {
            url = try store.create(header)
        } catch {
            Self.logger.error("session log not created: \(error.localizedDescription, privacy: .public)")
            url = nil
        }
    }

    // MARK: - Recording

    /// Gives `entry` its token, keeps it, writes it; returns it as kept.
    @discardableResult
    func record(_ entry: SessionLogEntry) -> SessionLogEntry {
        guard !isClosed else { return entry }
        var entry = entry
        entry.token = nextToken
        nextToken += 1
        entries.append(entry)
        if let url {
            bytes = (try? store.append(entry, to: url)) ?? bytes
            if bytes > maxBytes { trim() }
        }
        return entry
    }

    func callBegan(_ call: UUID) { callsInFlight.insert(call) }
    func callEnded(_ call: UUID) { callsInFlight.remove(call) }
    func isInFlight(_ call: UUID?) -> Bool { call.map(callsInFlight.contains) ?? false }

    /// Records the session's end; nothing after.
    func close(_ how: SessionLogLine.Ending) {
        record(SessionLogLine.closed(how))
        isClosed = true
    }

    /// Drops the oldest entries of the kinds that matter least until the
    /// log is within three quarters of its limit, then rewrites the file.
    private func trim() {
        guard let url else { return }
        let target = maxBytes * 3 / 4
        var sizes = entries.map { SessionLogStore.line(SessionLogRecord(entry: $0)).count }
        var total = sizes.reduce(0, +)
        var dropped = 0
        for keepChanges in [true, false] {
            var index = 0
            while total > target, index < entries.count {
                let kind = entries[index].kind
                let lesser = kind != .opened && (!keepChanges || (kind != .action && kind != .decision))
                if lesser {
                    total -= sizes.remove(at: index)
                    entries.remove(at: index)
                    dropped += 1
                } else {
                    index += 1
                }
            }
        }
        guard dropped > 0 else { return }
        var note = SessionLogLine.trimmed(dropped)
        note.token = nextToken
        nextToken += 1
        entries.append(note)
        bytes = (try? store.rewrite(url, header: header, entries: entries)) ?? bytes
    }

    // MARK: - Reading

    /// Entries after `token`; `expired` when the one right after it was
    /// dropped — the reader missed some.
    func entries(since token: Int) -> (entries: [SessionLogEntry], expired: Bool) {
        let kept = entries.filter { $0.token > token }
        let next = token + 1
        return (kept, token > 0 && next < nextToken && kept.first?.token != next)
    }
}
