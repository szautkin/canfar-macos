// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Settings ▸ Storage (plan 34 V): what Verbinal keeps in the person's
/// VOSpace, as the manifest there declares it, and how the last sync went.
/// The sync itself runs unseen; this is where it is seen.
struct StorageSettingsTab: View {
    @Environment(AppState.self) private var appState

    private var sync: StorageSyncModel { appState.storageSync }

    var body: some View {
        Form {
            if !appState.isAuthenticated {
                Section {
                    Label("Sign in to see what Verbinal keeps in your storage.", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                researchSection
                kindsSection
            }
        }
        .formStyle(.grouped)
        .onAppear { if appState.isAuthenticated, sync.status == nil { sync.run(.cameBack) } }
    }

    private var researchSection: some View {
        Section {
            Toggle("Keep Research in VOSpace", isOn: Binding(
                get: { sync.keepsResearch },
                set: { sync.setKeepsResearch($0) }))
                .pointable("settings.storage.keepResearch")
            if let note = kind("research")?.note {
                Label(note == ResearchKind.publicNote
                      ? String(localized: "Research is not synced while your .verbinal folder is readable by anyone. Make it private in Storage.")
                      : note, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let problem = sync.problem {
                Label(problem, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Research")
        } footer: {
            Text("Your observations' details, notes, tags and quality — not their files — the same on every device you sign in on. Turned on here, it is on for all of them; turned off, the files stay in your storage. Only while your .verbinal folder is private.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var kindsSection: some View {
        Section {
            ForEach(sync.status?.kinds ?? [], id: \.id) { kind in
                kindRow(kind)
            }
            HStack {
                if let last = sync.status?.lastSync {
                    Text("Last synced \(last, format: .relative(presentation: .named))")
                } else {
                    Text("Not synced yet")
                }
                if sync.status?.running == true { ProgressView().controlSize(.small) }
                Spacer()
                Button("Sync Now") { sync.syncNow() }
                    .disabled(sync.status?.running == true)
                    .pointable("settings.storage.syncNow")
            }
            .font(.caption)
            if let failure = sync.status?.lastFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Verbinal's Data in Your Storage")
        } footer: {
            Text("A manifest in your storage, .verbinal/manifest.json, says which kinds of Verbinal's data you keep there and where, for every Verbinal you use. Verbinal syncs them right after you sign in, quietly, and never deletes anything.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func kind(_ id: String) -> StorageSync.KindStatus? {
        sync.status?.kinds.first { $0.id == id }
    }

    private func kindRow(_ kind: StorageSync.KindStatus) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(kind.id))
                Text(kind.declared
                     ? String(localized: "\(kind.folder) · \(kind.items) items · \(SharedFormatters.bytes(kind.bytes))")
                     : String(localized: "Not kept in your storage"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let failure = kind.failure {
                    Text(failure).font(.caption).foregroundStyle(.orange)
                } else if kind.imported > 0 {
                    Text("\(kind.imported) brought to this Mac at the last sync").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if kind.declared {
                Button("Show in Storage") { appState.showStorageFolder(kind.folder) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    /// A kind as the person reads it.
    static func title(_ id: String) -> String {
        switch id {
        case "research": String(localized: "Research")
        case "imagePackages": String(localized: "Image package lists")
        case "computeRuns": String(localized: "Remote Compute runs")
        case "stagedScripts": String(localized: "Batch job scripts")
        case "exports": String(localized: "Exports")
        default: id
        }
    }
}
