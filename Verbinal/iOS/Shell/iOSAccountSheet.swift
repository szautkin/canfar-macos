// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The person, behind the button with their initials (plan 47 1.1): who is
/// signed in, the session reminders, About, the Terms, and Sign Out.
struct iOSAccountSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var reminders: ExpiryReminderScheduler
    var sessions: [PortalAttention.SessionFacts]

    @State private var showAbout = false
    @State private var showTerms = false

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    if let info = appState.userInfo {
                        if let first = info.firstName {
                            let name = [first, info.lastName].compactMap { $0 }.joined(separator: " ")
                            Label(name, systemImage: "person.fill")
                        }
                        if let email = info.email {
                            Label(email, systemImage: "envelope")
                        }
                        if let institute = info.institute {
                            Label(institute, systemImage: "building.2")
                        }
                    }
                    Label(appState.username, systemImage: "at")
                }

                Section {
                    Toggle("Remind me before a session expires", isOn: remindersOn)
                } footer: {
                    if reminders.isDenied {
                        Text("Notifications are off for Verbinal. Turn them on in Settings ▸ Notifications.")
                    } else {
                        Text("Thirty minutes before a session ends, even when Verbinal is closed.")
                    }
                }

                Section {
                    NavigationLink("AI Compute") {
                        iOSAIComputeSettingsView(settings: appState.aiComputeSettings, model: appState.remoteComputeModel)
                    }
                } footer: {
                    Text("The image, size and registry login of your compute session.")
                }

                Section {
                    Button("About Verbinal") { showAbout = true }
                    Button(LegalText.document(for: locale).termsLink) { showTerms = true }
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        dismiss()
                        Task { await appState.logout() }
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
                    .iosSheetChrome()
            }
            .sheet(isPresented: $showTerms) {
                LegalDocumentSheet()
                    .iosSheetChrome()
            }
        }
        .iosSheetChrome()
    }

    private var remindersOn: Binding<Bool> {
        Binding(
            get: { reminders.isEnabled },
            set: { on in Task { await reminders.setEnabled(on, sessions: sessions) } }
        )
    }
}

/// The person's initials in a circle: the Account button.
struct iOSAccountButton: View {
    @Environment(AppState.self) private var appState
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: initials)
                .font(.caption.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Account"))
    }

    private var initials: String {
        if let info = appState.userInfo, let first = info.firstName?.first {
            return String(first) + (info.lastName?.first.map(String.init) ?? "")
        }
        return appState.username.first.map { String($0).uppercased() } ?? "?"
    }
}
