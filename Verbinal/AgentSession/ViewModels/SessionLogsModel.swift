// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import Observation

/// The person's Session Logs: the list, one session's lines, export and
/// delete (plan 23 L4) — over the same reader, store and writer as the
/// assistant's tools.
@Observable
@MainActor
final class SessionLogsModel: Identifiable {
    /// Which entries the lines show.
    enum Show: String, CaseIterable, Identifiable {
        case all, actions, failures, decisions, calls
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .actions: String(localized: "Changes")
            case .failures: String(localized: "Failures")
            case .decisions: String(localized: "Decisions")
            case .calls: String(localized: "Calls")
            }
        }
    }

    private let query: SessionLogQuery
    private(set) var logs: [StoredSessionLog] = []
    private(set) var open: Set<UUID> = []
    var selection: Set<UUID> = [] {
        didSet { Task { await loadSelected() } }
    }
    private(set) var header: SessionLogHeader?
    private(set) var entries: [SessionLogEntry] = []
    var show: Show = .all
    /// What the last export or delete came to.
    private(set) var message: String?

    init(query: SessionLogQuery) {
        self.query = query
    }

    var totalBytes: Int { logs.map(\.bytes).reduce(0, +) }

    /// The lines, as the tools fold and filter them.
    var shown: [SessionLogEntry] {
        let folded = SessionLogQuery.folded(entries)
        guard show != .all else { return folded }
        return SessionLogQuery.filter(folded, .init(only: show.rawValue))
    }

    /// Only closed sessions can be deleted.
    var canDeleteSelection: Bool { !selection.isEmpty && selection.isDisjoint(with: open) }
    var closedCount: Int { logs.filter { !open.contains($0.header.session) }.count }

    func reload() async {
        open = await query.hub.openSessions
        logs = query.store.list()
        selection = selection.filter { id in logs.contains { $0.header.session == id } }
        await loadSelected()
    }

    private func loadSelected() async {
        guard selection.count == 1, let id = selection.first, let log = await query.log(of: id) else {
            header = nil
            entries = []
            return
        }
        header = log.header
        entries = log.entries
    }

    // MARK: - Export

    /// Asks where, then writes the selected logs — or all, when none is selected.
    func export(as format: SessionLogExport.Format) async {
        let ids = selection.isEmpty ? logs.map(\.header.session) : logs.map(\.header.session).filter(selection.contains)
        guard !ids.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(SessionLogExport.name(for: ids.count)).\(format.fileExtension)"
        panel.allowedContentTypes = [format == .text ? .plainText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var picked: [SessionLogExport.Log] = []
        for id in ids {
            if let log = await query.log(of: id) { picked.append((log.header, log.entries)) }
        }
        do {
            try SessionLogExport.write(picked, as: format, to: url)
            message = String(localized: "Exported \(picked.count) session logs to \(url.lastPathComponent).")
        } catch {
            message = String(localized: "Could not export: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete

    func deleteSelection() async {
        await delete(selection)
    }

    func deleteAllClosed() async {
        await delete(Set(logs.map(\.header.session)))
    }

    private func delete(_ ids: Set<UUID>) async {
        let open = await query.hub.openSessions
        let deleted = query.store.delete(ids, open: open)
        message = String(localized: "Deleted \(deleted.count) session logs.")
        selection = []
        await reload()
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logs.first?.url ?? query.store.directory])
    }
}
