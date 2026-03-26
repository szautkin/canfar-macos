// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

struct SessionListView: View {
    @Bindable var model: SessionListModel
    @State private var sessionToDelete: Session?
    @State private var showDeleteConfirmation = false
    @State private var eventsContent: String?
    @State private var logsContent: String?
    @State private var eventsTitle = ""
    @State private var showEventsSheet = false

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
                                .scaleEffect(0.5)
                            Text("Auto-refresh \(model.pollCountdown)s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if model.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    }

                    Button {
                        Task { await model.loadSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }

                if model.sessions.isEmpty && !model.isLoading {
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
                } else {
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
                    Label(model.errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog(
            "Delete Session",
            isPresented: $showDeleteConfirmation,
            presenting: sessionToDelete
        ) { session in
            Button("Delete", role: .destructive) {
                Task { await model.deleteSession(id: session.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("Are you sure you want to delete '\(session.sessionName)'? This action cannot be undone.")
        }
        .sheet(isPresented: $showEventsSheet) {
            SessionEventsSheet(
                title: eventsTitle,
                events: eventsContent ?? "No events available",
                logs: logsContent ?? "No logs available"
            )
        }
    }

    @ViewBuilder
    private func sessionCard(_ session: Session) -> some View {
        SessionCardView(
            session: session,
            onOpen: { model.openSessionInBrowser(session) },
            onDelete: {
                sessionToDelete = session
                showDeleteConfirmation = true
            },
            onRenew: { Task { await model.renewSession(id: session.id) } },
            onEvents: {
                Task {
                    eventsTitle = session.sessionName
                    async let e = model.getSessionEvents(id: session.id)
                    async let l = model.getSessionLogs(id: session.id)
                    eventsContent = await e
                    logsContent = await l
                    showEventsSheet = true
                }
            }
        )
    }
}
