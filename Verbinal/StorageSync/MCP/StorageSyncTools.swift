// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What an assistant is told of Verbinal's data in VOSpace (plan 34 V).
struct StorageKindsOut: Encodable, Sendable {
    struct Kind: Encodable, Sendable {
        let id: String
        let title: String
        /// The manifest declares it: the person keeps it in VOSpace.
        let declared: Bool
        let folder: String
        let items: Int
        let bytes: Int64
        let lastSyncISO: String?
        let imported: Int
        let sent: Int
        let note: String?
        let failure: String?
        /// `off`, `waiting`, `syncing`, `synced` or `failed` (plan 38).
        let state: String
        /// Its conflicts waiting for the person (plan 45).
        let conflicts: Int
    }

    let manifest: String
    /// False for an account without CANFAR storage: nothing is synced, the
    /// person's work stays on this Mac. Absent until a sync looked.
    let hasStorage: Bool?
    let hasManifest: Bool
    let lastSyncISO: String?
    let lastFailure: String?
    let running: Bool
    /// Who paused the sync, why, when, and where it had got to (plan 40).
    let paused: Paused?
    /// The kind syncing now, and how far it has got.
    let syncing: Syncing?
    /// Its task on the activity bar: what pause_activity and resume_activity take.
    let activityTask: Int?
    let kinds: [Kind]
    /// Every conflict waiting for the person: list_sync_conflicts lists them.
    let conflicts: Int
    let note: String

    struct Paused: Encodable, Sendable {
        let by: String
        let why: String?
        let atISO: String
        let kind: String?
        let done: Int?
        let total: Int?
    }

    struct Syncing: Encodable, Sendable {
        let kind: String
        let title: String
        let done: Int
        let total: Int
    }

    init(_ status: StorageSync.Status) {
        let iso = SharedFormatters.iso8601
        paused = status.paused.map { Paused(by: $0.by, why: $0.why, atISO: iso.string(from: $0.at), kind: $0.kind,
                                            done: $0.done, total: $0.total) }
        syncing = status.progress.map { Syncing(kind: $0.kind, title: StorageSettingsTab.title($0.kind), done: $0.done, total: $0.total) }
        activityTask = status.activityTask
        manifest = StorageManifest.path
        hasStorage = status.hasStorage
        hasManifest = status.hasManifest
        lastSyncISO = status.lastSync.map { iso.string(from: $0) }
        lastFailure = status.lastFailure
        running = status.running
        kinds = status.kinds.map { kind in
            Kind(id: kind.id, title: StorageSettingsTab.title(kind.id), declared: kind.declared, folder: kind.folder,
                 items: kind.items, bytes: kind.bytes, lastSyncISO: kind.lastSync.map { iso.string(from: $0) },
                 imported: kind.imported, sent: kind.sent, note: kind.note, failure: kind.failure, state: kind.state.name,
                 conflicts: status.conflicts.count { $0.kind == kind.id })
        }
        conflicts = status.conflicts.count
        note = "Which of their work the person keeps in VOSpace is their choice, one collection at a time, in Settings ▸ Storage (`declared`); files there are read and changed with the storage tools."
    }
}

/// `list_storage_kinds` — which kinds of Verbinal's data the person keeps
/// in VOSpace, as the manifest declares them, and how the last sync went.
struct ListStorageKindsTool: JSONReadTool {
    struct Args: Decodable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_storage_kinds",
        description: "List the kinds of Verbinal's data the person keeps in their VOSpace, as the manifest .verbinal/manifest.json declares them: the collections of their work they chose to keep there, each by itself (Research, workflows, saved queries, recent searches, guides for assistants, Remote Compute history, batch job history, added images, recent launches, Portal launch defaults), and what Verbinal keeps there anyway (the CANFAR images' package lists, Remote Compute results, batch job scripts, exports). Each with its folder, how many items and bytes, and what the last sync brought to this Mac or sent. While a sync runs, `syncing` says which kind and how far (`done` of `total`); `paused` says who paused it, why and where it had got to; `activityTask` is its task on the activity bar, for pause_activity and resume_activity. `conflicts` counts what waits for the person to choose, each kind's and in all: list_sync_conflicts lists them. `hasStorage: false`: the account has no CANFAR storage, and nothing is synced. Verbinal syncs by itself after sign-in; sync_storage syncs now. Requires sign-in.",
        schema: #"{ "type": "object", "properties": {}, "additionalProperties": false }"#
    )

    let status: @Sendable () async throws -> StorageSync.Status

    func handle(_ args: Args, context: AIToolContext) async throws -> StorageKindsOut {
        StorageKindsOut(try await status())
    }
}

/// `sync_storage` — the sync, now, as Settings ▸ Storage's Sync Now.
struct SyncStorageTool: JSONReadTool {
    static var verbClass: VerbClass { .viewState }

    struct Args: Decodable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "sync_storage",
        description: "Sync Verbinal's data in VOSpace now, as Sync Now in Settings ▸ Storage does, and answer how it went (list_storage_kinds' answer). It brings to this Mac what another device kept — package lists, results, and the collections of their work the person keeps there — and sends this Mac's changes to those collections; it never deletes. Usually not needed: Verbinal syncs after sign-in by itself. A paused sync stays paused: this answers who paused it, and resume_activity resumes it. Requires sign-in. Live-applied.",
        schema: #"{ "type": "object", "properties": {}, "additionalProperties": false }"#
    )

    let sync: @Sendable () async throws -> StorageSync.Status

    func handle(_ args: Args, context: AIToolContext) async throws -> StorageKindsOut {
        StorageKindsOut(try await sync())
    }
}
