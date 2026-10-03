// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SessionListView: View {
    @Bindable var model: SessionListModel
    /// Opens the launch form; no button without it.
    var onLaunch: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL
    @State private var sessionToDelete: Session?
    @State private var showDeleteConfirmation = false
    @State private var eventsContent: String?
    @State private var logsContent: String?
    @State private var eventsTitle = ""
    @State private var showEventsSheet = false

    // Action feedback
    @State private var showActionSheet = false
    @State private var actionInProgress = false
    @State private var actionSuccess = false
    @State private var actionError = false
    @State private var actionTitle = ""
    @State private var actionMessage = ""

    /// Boundary discriminator for the empty↔content cross-fade. The header
    /// spinner covers the loading affordance, so there is no `.loading`
    /// branch here; the error `Label` renders separately below.
    private var sessionsState: DataState {
        (model.sessions.isEmpty && !model.isLoading) ? .empty : .content
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Label(
                        "Active Sessions (\(model.sessions.count))",
                        systemImage: "rectangle.stack"
                    )
                    .font(.headline)

                    if model.isPolling {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Auto-refresh \(model.pollCountdown)s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        Task { await model.loadSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh active sessions")
                    .accessibilityLabel("Refresh sessions")

                    if let onLaunch {
                        Button(action: onLaunch) {
                            Label("Launch Session", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .pointable("portal.openLaunchForm")
                    }
                }

                // Cross-fade the empty↔content BOUNDARY only. The 15 s
                // auto-poll keeps the state at `.content` and swaps cards in
                // place with no animation — never a flickering carousel.
                DataStateContainer(state: sessionsState) {
                    EmptyView()
                } empty: {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.title)
                                .foregroundStyle(.tertiary)
                            Text("No active sessions")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                } error: {
                    EmptyView()
                } content: {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.sessions) { session in
                            sessionCard(session)
                                .frame(maxWidth: .infinity)
                        }
                        // Invisible spacers keep cards from stretching when < 3
                        ForEach(0..<max(0, 3 - model.sessions.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }

                if model.hasError {
                    InlineErrorLabel(message: model.errorMessage)
                }
            }
        }
        .uiPresented("Delete the Session?", .confirmation, isPresented: $showDeleteConfirmation)
        .confirmationDialog(
            "Delete Session",
            isPresented: $showDeleteConfirmation,
            presenting: sessionToDelete
        ) { session in
            Button("Delete", role: .destructive) {
                performAction(
                    title: String(localized: "Deleting Session"),
                    successMessage: String(localized: "Session '\(session.sessionName)' deleted.")
                ) {
                    await model.deleteSession(id: session.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("Are you sure you want to delete '\(session.sessionName)'? This action cannot be undone.")
        }
        .uiPresented("Session Action", .sheet, isPresented: $showActionSheet)
        .sheet(isPresented: $showActionSheet) {
            actionFeedbackSheet
        }
        .uiPresented("Session Events", .sheet, isPresented: $showEventsSheet)
        .sheet(isPresented: $showEventsSheet) {
            SessionEventsSheet(
                title: eventsTitle,
                events: eventsContent ?? "No events available",
                logs: logsContent ?? "No logs available"
            )
        }
    }

    private func performAction(title: String, successMessage: String, action: @escaping () async -> Void) {
        actionTitle = title
        actionMessage = ""
        actionInProgress = true
        actionSuccess = false
        actionError = false
        showActionSheet = true
        Task {
            await action()
            actionInProgress = false
            if model.hasError {
                actionError = true
                actionMessage = model.errorMessage
            } else {
                actionSuccess = true
                actionMessage = successMessage
            }
        }
    }

    @ViewBuilder
    private var actionFeedbackSheet: some View {
        VStack(spacing: 20) {
            if actionInProgress {
                ProgressView()
                    .controlSize(.large)
                Text("\(actionTitle)…")
                    .font(.body)
            } else if actionSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text(actionTitle)
                    .font(.headline)
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if actionError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text("Action Failed")
                    .font(.headline)
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !actionInProgress {
                Button("Done") {
                    showActionSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .sheetFrame(width: 380)
        // Escape always dismisses — including mid-action, so a hung
        // request can't trap the user in a buttonless sheet (the action
        // itself continues in its Task and lands its result silently).
        .onEscape { showActionSheet = false }
    }

    @ViewBuilder
    private func sessionCard(_ session: Session) -> some View {
        SessionCardView(
            session: session,
            onOpen: {
                if let url = model.connectURL(for: session) { openURL(url) }
            },
            onDelete: {
                sessionToDelete = session
                showDeleteConfirmation = true
            },
            onRenew: {
                performAction(
                    title: String(localized: "Renewing Session"),
                    successMessage: String(localized: "Session '\(session.sessionName)' renewed.")
                ) {
                    await model.renewSession(id: session.id)
                }
            },
            onEvents: {
                Task {
                    eventsTitle = session.sessionName
                    async let e = model.getSessionEvents(id: session.id)
                    async let l = model.getSessionLogs(id: session.id)
                    eventsContent = SessionDisplay.logResultText(await e, emptyFallback: String(localized: "No events available"))
                    logsContent = SessionDisplay.logResultText(await l, emptyFallback: String(localized: "No logs available"))
                    showEventsSheet = true
                }
            }
        )
    }
}
