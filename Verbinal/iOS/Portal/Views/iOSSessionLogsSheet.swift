// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// A session's events and logs, on iPhone and iPad alike. Opens at once and
/// loads inside, so a tap always answers.
struct iOSSessionLogsSheet: View {
    let session: Session
    var model: SessionListModel

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    @State private var events: String?
    @State private var logs: String?

    private var isLoading: Bool { events == nil || logs == nil }
    private var currentContent: String { (selectedTab == 0 ? events : logs) ?? "" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Events").tag(0)
                    Text("Logs").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if isLoading {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                } else {
                    ScrollView {
                        Text(currentContent.isEmpty ? String(localized: "No data available") : currentContent)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .background(Color.textFieldBackground)
                }
            }
            .navigationTitle(session.sessionName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        PlatformClipboard.copy(currentContent)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(Text("Copy"))
                    .disabled(isLoading || currentContent.isEmpty)
                }
            }
        }
        .task {
            async let e = model.getSessionEvents(id: session.id)
            async let l = model.getSessionLogs(id: session.id)
            events = SessionDisplay.logResultText(await e, emptyFallback: String(localized: "No events available"))
            logs = SessionDisplay.logResultText(await l, emptyFallback: String(localized: "No logs available"))
        }
        .iosSheetChrome()
    }
}
