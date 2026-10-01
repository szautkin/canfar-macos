// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI

/// "An assistant wants to start a session" (plan 25 S): who is asking —
/// the client as its connection names it, and the assistant as it presents
/// itself — and the instructions the person gives the session.
struct SessionApprovalView: View {
    let request: SessionApprovals.Request
    let onAllow: (String) -> Void
    let onDeny: () -> Void

    @State private var instructions: String
    private let defaultInstructions: String

    init(request: SessionApprovals.Request, defaultInstructions: String,
         onAllow: @escaping (String) -> Void, onDeny: @escaping () -> Void) {
        self.request = request
        self.onAllow = onAllow
        self.onDeny = onDeny
        self.defaultInstructions = defaultInstructions
        _instructions = State(initialValue: defaultInstructions)
    }

    private var words: Int { SessionApprovals.words(instructions) }
    private var tooLong: Bool { words > SessionApprovals.maxWords }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("An assistant wants to start a session", systemImage: "person.badge.key")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Client").foregroundStyle(.secondary)
                    Text(request.client).textSelection(.enabled)
                }
                GridRow {
                    Text("Connection").foregroundStyle(.secondary)
                    Text(request.mcpVersion.map { "MCP \($0)" } ?? String(localized: "MCP"))
                }
                GridRow {
                    Text("Asked").foregroundStyle(.secondary)
                    Text(request.askedAt, format: .dateTime.hour().minute().second())
                }
            }
            .font(.callout)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.agent + (request.model.map { " · \($0)" } ?? ""))
                        .font(.callout.weight(.medium))
                    if let purpose = request.purpose {
                        Text(purpose).font(.callout)
                    }
                    Text("As the assistant describes itself — Verbinal cannot check it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            } label: {
                Text("How the assistant presents itself")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Instructions for this session").font(.callout.weight(.medium))
                    Spacer()
                    Button("Reset") { instructions = defaultInstructions }
                        .controlSize(.small)
                        .disabled(instructions == defaultInstructions)
                }
                TextEditor(text: $instructions)
                    .font(.callout)
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                Text("\(words) of \(SessionApprovals.maxWords) words")
                    .font(.caption)
                    .foregroundStyle(tooLong ? .red : .secondary)
                Text("The assistant is told to follow them for the whole session, and the session's log keeps them. Verbinal cannot stop an assistant using its other tools or connections outside Verbinal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Deny", role: .cancel, action: onDeny)
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { onAllow(instructions) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tooLong)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// The window the approval shows in: it comes forward over everything
/// when an assistant asks, and goes when no one is waiting (plan 25 S).
@MainActor
final class SessionApprovalWindow {
    private let approvals: SessionApprovals
    private var window: NSWindow?
    private var showing: UUID?

    init(approvals: SessionApprovals) {
        self.approvals = approvals
        watch()
    }

    /// Follows the pending requests, as they come and go.
    private func watch() {
        withObservationTracking {
            _ = approvals.pending
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.watch()
            }
        }
    }

    private func refresh() {
        guard let request = approvals.pending.first else {
            window?.close()
            window = nil
            showing = nil
            return
        }
        guard request.id != showing else { return }
        showing = request.id
        let approvals = approvals
        let view = SessionApprovalView(
            request: request, defaultInstructions: approvals.defaultInstructions,
            onAllow: { approvals.allow(request.id, instructions: $0) },
            onDeny: { approvals.decline(request.id) })
        let window = self.window ?? NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = String(localized: "Assistant Session")
        // The person's decision: never a target an assistant can point at (plan 27).
        window.identifier = NSUserInterfaceItemIdentifier(PointableID.Window.sessionApproval.identifier)
        window.contentViewController = NSHostingController(rootView: view)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
