// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The app's menu, behind the button with the person's initials (plan 48,
/// D1): who is signed in, then the files — on this device and in storage —
/// the settings, help, and Sign Out. The four places keep the tab bar.
struct iOSMenuSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var reminders: ExpiryReminderScheduler
    var sessions: [PortalAttention.SessionFacts]
    var library: DeviceLibrary
    var storage: StorageModel
    /// Opens a file in FITS or Cube; the shell closes the menu.
    var onOpen: (FileRef) -> Void
    /// Closes the viewers showing these files.
    var onClose: ([URL]) -> Void

    @State private var showAbout = false
    @State private var showTerms = false

    var body: some View {
        NavigationStack {
            List {
                profile
                ForEach(iOSMenuEntry.layout, id: \.section) { group in
                    Section {
                        ForEach(group.entries) { row($0) }
                    } header: {
                        header(group.section)
                    } footer: {
                        footer(group.section)
                    }
                }
            }
            .navigationTitle("Verbinal")
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
            .task { await library.reload() }
        }
        .iosSheetChrome()
    }

    // MARK: - Who

    private var profile: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: displayName).font(.headline)
                Text(verbatim: [appState.username, appState.userInfo?.institute].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let email = appState.userInfo?.email {
                    Text(verbatim: email).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var displayName: String {
        let name = [appState.userInfo?.firstName, appState.userInfo?.lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? appState.username : name
    }

    // MARK: - The entries

    @ViewBuilder
    private func row(_ entry: iOSMenuEntry) -> some View {
        switch entry {
        case .onThisDevice:
            NavigationLink {
                iOSDeviceFilesView(library: library, onOpen: onOpen, onClose: onClose)
            } label: {
                LabeledContent {
                    Text(verbatim: FilesWording.bytes(library.bytes()))
                } label: {
                    Label(iOSDeviceFilesView.deviceTitle, systemImage: iOSDeviceFilesView.deviceIcon)
                }
            }
        case .yourStorage:
            NavigationLink {
                iOSYourStorageView(storage: storage, library: library, onOpen: onOpen)
            } label: {
                LabeledContent {
                    if storage.hasData {
                        Text(verbatim: (storage.usagePercent / 100).formatted(.percent.precision(.fractionLength(0))))
                    }
                } label: {
                    Label("Your Storage", systemImage: "externaldrive")
                }
            }
        case .reminders:
            Toggle(isOn: remindersOn) { Label("Session Reminders", systemImage: "bell") }
        case .downloadsCap:
            Picker(selection: Bindable(library).capGB) {
                ForEach(FilesRules.capChoices, id: \.self) { Text(verbatim: "\($0) GB").tag($0) }
            } label: {
                Label("Downloads Kept Up To", systemImage: "arrow.down.circle")
            }
        case .aiCompute:
            NavigationLink {
                iOSAIComputeSettingsView(settings: appState.aiComputeSettings, model: appState.remoteComputeModel)
            } label: {
                Label("AI Compute", systemImage: "cpu")
            }
        case .help:
            Link(destination: iOSMenuEntry.helpURL) {
                Label("Verbinal Help", systemImage: "questionmark.circle")
            }
            .accessibilityHint(Text("Opens the user manual in Safari"))
        case .about:
            Button { showAbout = true } label: { Label("About Verbinal", systemImage: "info.circle") }
        case .terms:
            Button { showTerms = true } label: {
                Label(LegalText.document(for: locale).termsLink, systemImage: "doc.text")
            }
        case .signOut:
            Button("Sign Out", role: .destructive) {
                dismiss()
                Task { await appState.logout() }
            }
        }
    }

    @ViewBuilder
    private func header(_ section: iOSMenuEntry.Section) -> some View {
        switch section {
        case .files: Text("Files")
        case .settings: Text("Settings")
        case .help: Text("Help")
        case .account: EmptyView()
        }
    }

    @ViewBuilder
    private func footer(_ section: iOSMenuEntry.Section) -> some View {
        if section == .settings {
            if reminders.isDenied {
                Text("Notifications are off for Verbinal. Turn them on in Settings ▸ Notifications.")
            } else {
                Text("Session reminders come thirty minutes before a session ends, even when Verbinal is closed.")
            }
        }
    }

    private var remindersOn: Binding<Bool> {
        Binding(
            get: { reminders.isEnabled },
            set: { on in Task { await reminders.setEnabled(on, sessions: sessions) } }
        )
    }
}

/// The person's initials in a circle: the menu's button, in the same place
/// on every screen.
struct iOSMenuButton: View {
    @Environment(AppState.self) private var appState
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let initials {
                    Text(verbatim: initials).font(.caption.weight(.semibold))
                } else {
                    Image(systemName: "person.fill").font(.caption)
                }
            }
            .frame(width: 30, height: 30)
            .background(Color.accentColor.opacity(0.15), in: Circle())
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Menu"))
        .accessibilityHint(Text("Files, settings, help and your account"))
    }

    private var initials: String? {
        if let info = appState.userInfo, let first = info.firstName?.first {
            return String(first) + (info.lastName?.first.map(String.init) ?? "")
        }
        return appState.username.first.map { String($0).uppercased() }
    }
}
