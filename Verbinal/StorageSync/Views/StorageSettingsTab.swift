// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Settings ▸ Storage (plan 34 V, 36 3.2): which of their work the person
/// keeps in their CANFAR storage — each collection their own choice — and
/// what else Verbinal keeps there, as the manifest declares it, with how the
/// last sync went. The sync itself runs unseen; this is where it is seen.
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
            } else if sync.hasStorage == false {
                Section {
                    Label("Your account has no CANFAR storage, so your work stays on this Mac.", systemImage: "externaldrive.badge.xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                workSection
                kindsSection
            }
        }
        .formStyle(.grouped)
        .onAppear { if appState.isAuthenticated, sync.status == nil { sync.run(.cameBack) } }
    }

    private var workSection: some View {
        Section {
            if kinds(work: true).contains(where: { $0.note == CollectionSync.publicNote }) {
                Label("Your work is not synced while your .verbinal folder is readable by anyone. Make it private in Storage.",
                      systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(kinds(work: true), id: \.id) { kind in
                Toggle(isOn: Binding(get: { sync.keeps(kind.id) }, set: { sync.setKeeps(kind.id, $0) })) {
                    kindLabel(kind)
                }
                .pointable("settings.storage.keep.\(kind.id)")
            }
            if let problem = sync.problem {
                Label(problem, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Your Work in VOSpace")
        } footer: {
            Text("Choose what Verbinal keeps in your CANFAR storage, to have it the same on every device you sign in on. A choice made here is made for all of them; turned off, the files stay in your storage. Nothing moves while your .verbinal folder is readable by anyone. Sign-ins, what assistants may do, session logs and the files on this Mac stay on it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var kindsSection: some View {
        Section {
            ForEach(kinds(work: false), id: \.id) { kind in
                HStack(alignment: .firstTextBaseline) {
                    kindLabel(kind)
                    Spacer()
                    if kind.declared {
                        Button("Show in Storage") { appState.showStorageFolder(kind.folder) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
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

    /// The person's collections, or the rest of what Verbinal keeps there.
    private func kinds(work: Bool) -> [StorageSync.KindStatus] {
        (sync.status?.kinds ?? []).filter { StorageKindCatalog.work.contains($0.id) == work }
    }

    private func kindLabel(_ kind: StorageSync.KindStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.title(kind.id))
            Text(kind.declared
                 ? String(localized: "\(kind.folder) · \(kind.items) items · \(SharedFormatters.bytes(kind.bytes))")
                 : String(localized: "Not kept in your storage"))
                .font(.caption)
                .foregroundStyle(.secondary)
            switch kind.state {
            case .failed(let why):
                Text(why).font(.caption).foregroundStyle(.orange)
            case .syncing:
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            case .synced where kind.imported > 0:
                Text("\(kind.imported) brought to this Mac at the last sync").font(.caption).foregroundStyle(.secondary)
            case .waiting:
                Text("Waiting for its first sync").font(.caption).foregroundStyle(.secondary)
            case .off, .synced:
                EmptyView()
            }
        }
    }

    /// A kind as the person reads it.
    static func title(_ id: String) -> String {
        switch id {
        case "research": String(localized: "Research")
        case "marks": String(localized: "Marks on images")
        case "bookmarks": String(localized: "Sky bookmarks")
        case "workflows": String(localized: "Workflows")
        case "savedQueries": String(localized: "Saved queries")
        case "recentSearches": String(localized: "Recent searches")
        case "guides": String(localized: "Guides for assistants")
        case "computeHistory": String(localized: "Remote Compute history")
        case "jobHistory": String(localized: "Batch job history")
        case "userImages": String(localized: "Your added images")
        case "recentLaunches": String(localized: "Recent launches")
        case "portalDefaults": String(localized: "Portal launch defaults")
        case "results": String(localized: "Results: downloads, cutouts, search exports and figures")
        case "imagePackages": String(localized: "Image package lists")
        case "computeRuns": String(localized: "Remote Compute runs")
        case "stagedScripts": String(localized: "Batch job scripts")
        case "exports": String(localized: "Exports")
        default: id
        }
    }
}
