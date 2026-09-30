// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// Settings ▸ AI Agent ▸ Session Logs: every assistant session kept, what
/// happened in each and why, to read, export or delete (plan 23 L4).
struct SessionLogsView: View {
    @State var model: SessionLogsModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var confirmingDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sessions
                    .frame(width: 280)
                Divider()
                detail
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 540)
        .task { await model.reload() }
        .confirmationDialog(String(localized: "Delete \(model.selection.count) session logs?"), isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.deleteSelection() } }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(String(localized: "Delete \(model.closedCount) closed session logs?"), isPresented: $confirmingDeleteAll) {
            Button("Delete", role: .destructive) { Task { await model.deleteAllClosed() } }
        } message: {
            Text("This cannot be undone. Open sessions keep their logs.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Session Logs").font(.headline)
            Spacer()
            Menu("Export") {
                Button("Export as Text…") { Task { await model.export(as: .text) } }
                Button("Export as JSON Lines…") { Task { await model.export(as: .jsonl) } }
            }
            .fixedSize()
            .disabled(model.logs.isEmpty)
            Button("Delete…", role: .destructive) { confirmingDelete = true }
                .disabled(!model.canDeleteSelection)
            Button("Delete All Closed…", role: .destructive) { confirmingDeleteAll = true }
                .disabled(model.closedCount == 0)
            Button("Show in Finder") { model.showInFinder() }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var sessions: some View {
        List(selection: $model.selection) {
            ForEach(model.logs) { log in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(log.header.client).font(.callout.weight(.medium))
                        if model.open.contains(log.header.session) {
                            Text("Open")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .background(Color.green.opacity(0.18), in: Capsule())
                        }
                    }
                    Text(log.header.opened, format: .dateTime.day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(log.actions) changes · \(log.failures) failures · \(ByteCountFormatter.string(fromByteCount: Int64(log.bytes), countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(log.failures > 0 ? .red : .secondary)
                }
                .tag(log.header.session)
            }
        }
        .overlay {
            if model.logs.isEmpty {
                ContentUnavailableView("No session logs yet", systemImage: "list.bullet.rectangle",
                                       description: Text("A log is kept for each assistant that connects over MCP."))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let header = model.header {
            VStack(alignment: .leading, spacing: 8) {
                Text("Verbinal \(header.app) · macOS \(header.macOS) · Auto-apply \(header.autoApply ? String(localized: "on") : String(localized: "off"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Picker("Show", selection: $model.show) {
                    ForEach(SessionLogsModel.Show.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                List(model.shown) { entry in
                    SessionLogEntryRow(entry: entry)
                }
            }
            .padding(12)
        } else {
            ContentUnavailableView(model.selection.count > 1 ? "\(model.selection.count) sessions selected" : "Select a session",
                                   systemImage: "text.alignleft")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Text(SessionLogRetention.rule)
            Spacer()
            if let message = model.message { Text(message) }
            Text(ByteCountFormatter.string(fromByteCount: Int64(model.totalBytes), countStyle: .file))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    }
}

/// One line of a session log: its time and sentence; a call opens to its
/// requests, any entry to its ids and codes.
private struct SessionLogEntryRow: View {
    let entry: SessionLogEntry
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array((entry.requests ?? []).enumerated()), id: \.offset) { _, request in
                    Text("· \(request.name): \(request.meaning), \(CallTiming.duration(request.seconds)) of \(Int(request.timeout)) s\(request.code.map { ", \($0)" } ?? "")")
                }
                Text(details)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
        } label: {
            Text(SessionLogLine.timed(entry))
                .font(entry.kind == .action || entry.kind == .decision ? .callout.weight(.medium) : .callout)
                .foregroundStyle(entry.isFailure || entry.kind == .request ? .red : .primary)
                .textSelection(.enabled)
        }
    }

    /// "token 12 · call 3F2A… · proposal 9C1B… · task 7 · HTTP 503".
    private var details: String {
        var parts = ["token \(entry.token)", entry.kind.rawValue]
        if let who = entry.who { parts.append(who.rawValue) }
        if let call = entry.ids.call { parts.append("call \(call.uuidString.prefix(8))") }
        if let proposal = entry.ids.proposal { parts.append("proposal \(proposal.uuidString.prefix(8))") }
        if let task = entry.ids.task { parts.append("task \(task)") }
        if let status = entry.codes?.status { parts.append("HTTP \(status)") }
        if let error = entry.codes?.error { parts.append("URLError \(error)") }
        if let tag = entry.codes?.tag { parts.append(tag) }
        return parts.joined(separator: " · ")
    }
}
