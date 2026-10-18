// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import MCPCore
import SwiftUI
import VerbinalKit

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
                if !sync.conflicts.isEmpty { conflictsSection }
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
                if let paused = sync.status?.paused {
                    Text(Self.pausedLine(paused))
                } else if let count = sync.current {
                    ProgressView().controlSize(.small)
                    Text("Syncing… \(Self.title(count.kind)), \(count.done) of \(count.total)")
                } else if let last = sync.status?.lastSync {
                    Text("Last synced \(last, format: .relative(presentation: .named))")
                } else {
                    Text("Not synced yet")
                }
                if sync.status?.running == true, sync.current == nil, sync.status?.paused == nil {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                // Pause and Resume are the bar's too, and an assistant's
                // pause_activity and resume_activity (plan 40).
                if sync.isPaused {
                    Button("Resume") { sync.resume() }
                        .help("Go on from where it stopped")
                        .pointable("settings.storage.resume")
                } else {
                    Button("Pause") { sync.pause() }
                        .help("Stop syncing where it is, until you resume it")
                        .pointable("settings.storage.pause")
                    Button("Sync Now") { sync.syncNow() }
                        .disabled(sync.status?.running == true)
                        .pointable("settings.storage.syncNow")
                }
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

    /// What the person decides (plan 45): each change two devices made
    /// differently, storage's kept meanwhile, and each removal one made of
    /// what the other changed, the change kept meanwhile.
    private var conflictsSection: some View {
        Section {
            ForEach(sync.conflicts) { conflict in
                SyncConflictRow(conflict: conflict) { sync.resolve(conflict.id, choosing: $0) }
            }
        } header: {
            Text("Conflicts")
        } footer: {
            Text("Two devices changed the same thing differently, or one removed what the other changed. Until you choose, the version in your storage is kept, and a change is kept over a removal. What you choose goes to every device.")
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

    /// "Paused by you · Image package lists, 120 of 288".
    static func pausedLine(_ paused: StorageSyncState.Paused) -> String {
        let by = ActivitySummary.pausedBy(Initiator(rawValue: paused.by) ?? .person)
        let at: String? = switch (paused.kind, paused.done) {
        case (let kind?, let done?): "\(title(kind)), " + String(localized: "\(done) of \(paused.total ?? done)")
        case (let kind?, nil): title(kind)
        default: nil
        }
        return [by, at].compactMap { $0 }.joined(separator: " · ")
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


/// One conflict, as the person decides it: what it is, each side's value,
/// and the two choices.
struct SyncConflictRow: View {
    let conflict: SyncConflict
    let choose: (SyncConflict.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.heading(conflict))
            Text(Self.reasonLine(conflict))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(conflict.fields, id: \.path) { field in
                Text(Self.fieldLine(field, other: Self.other(conflict)))
                    .font(.caption)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                switch conflict.reason {
                case .bothChanged:
                    Button("Keep the Other's") { choose(.theirs) }
                        .help("The version in your storage stays, as every device has it")
                        .pointable("settings.storage.conflict.\(conflict.id).theirs")
                    Button("Keep This Mac's") { choose(.mine) }
                        .help("This Mac's goes to your storage, and to every device")
                        .pointable("settings.storage.conflict.\(conflict.id).mine")
                case .removedThere, .removedHere:
                    Button("Remove It", role: .destructive) { choose(conflict.removing) }
                        .help("Removed on every device, as it was on one")
                        .pointable("settings.storage.conflict.\(conflict.id).\(conflict.removing.rawValue)")
                    Button("OK") { choose(conflict.keeping) }
                        .help("It stays, with its change, on every device")
                        .pointable("settings.storage.conflict.\(conflict.id).\(conflict.keeping.rawValue)")
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    /// The other device, by its name.
    static func other(_ conflict: SyncConflict) -> String {
        conflict.otherDevice.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "another device")
    }

    /// "Saved queries: the query "M31 deep"".
    static func heading(_ conflict: SyncConflict) -> String {
        "\(StorageSettingsTab.title(conflict.kind)): \(conflict.title)"
    }

    static func reasonLine(_ conflict: SyncConflict) -> String {
        let other = other(conflict)
        return switch conflict.reason {
        case .bothChanged:
            String(localized: "Changed differently on \(other) and on this Mac. The version in your storage is kept; this Mac's waits for you.")
        case .removedThere:
            String(localized: "Removed on \(other), but changed on this Mac: it stays, with this Mac's change.")
        case .removedHere:
            String(localized: "Removed on this Mac, but changed on \(other): it is back, with that change.")
        }
    }

    /// "note.text — this Mac: seeing 0.6 · MacBook: seeing 0.8".
    static func fieldLine(_ field: SyncMerge.Conflict, other: String) -> String {
        let mine = value(field.mine), theirs = value(field.theirs)
        return String(localized: "\(field.field) — this Mac: \(mine) · \(other): \(theirs)")
    }

    /// A value as the person reads it; nil: removed.
    static func value(_ value: JSONValue?) -> String {
        switch value {
        case nil: String(localized: "removed")
        case .null?: "—"
        case .string(let text)?: text
        case .bool(let yes)?: yes ? String(localized: "yes") : String(localized: "no")
        case .int(let number)?: "\(number)"
        case .double(let number)?: number.formatted()
        case .array(let items)?: items.map { Self.value($0) }.joined(separator: ", ")
        case .object?:
            (try? JSONEncoder.sortedCompact.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}

private extension JSONEncoder {
    static let sortedCompact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
