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
    }

    let manifest: String
    /// False for an account without CANFAR storage: nothing is synced, the
    /// person's work stays on this Mac. Absent until a sync looked.
    let hasStorage: Bool?
    let hasManifest: Bool
    let lastSyncISO: String?
    let lastFailure: String?
    let running: Bool
    let kinds: [Kind]
    let note: String

    init(_ status: StorageSync.Status) {
        let iso = SharedFormatters.iso8601
        manifest = StorageManifest.path
        hasStorage = status.hasStorage
        hasManifest = status.hasManifest
        lastSyncISO = status.lastSync.map { iso.string(from: $0) }
        lastFailure = status.lastFailure
        running = status.running
        kinds = status.kinds.map {
            Kind(id: $0.id, title: StorageSettingsTab.title($0.id), declared: $0.declared, folder: $0.folder,
                 items: $0.items, bytes: $0.bytes, lastSyncISO: $0.lastSync.map { iso.string(from: $0) },
                 imported: $0.imported, sent: $0.sent, note: $0.note, failure: $0.failure, state: $0.state.name)
        }
        note = "Which of their work the person keeps in VOSpace is their choice, one collection at a time, in Settings ▸ Storage (`declared`); files there are read and changed with the storage tools."
    }
}

/// `list_storage_kinds` — which kinds of Verbinal's data the person keeps
/// in VOSpace, as the manifest declares them, and how the last sync went.
struct ListStorageKindsTool: JSONReadTool {
    struct Args: Decodable, Sendable {}

    let definition = AIToolDefinition.withStaticSchema(
        name: "list_storage_kinds",
        description: "List the kinds of Verbinal's data the person keeps in their VOSpace, as the manifest .verbinal/manifest.json declares them: the collections of their work they chose to keep there, each by itself (Research, workflows, saved queries, recent searches, guides for assistants, Remote Compute history, batch job history, added images, recent launches, Portal launch defaults), and what Verbinal keeps there anyway (the CANFAR images' package lists, Remote Compute results, batch job scripts, exports). Each with its folder, how many items and bytes, and what the last sync brought to this Mac or sent. `hasStorage: false`: the account has no CANFAR storage, and nothing is synced. Verbinal syncs by itself after sign-in; sync_storage syncs now. Requires sign-in.",
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
        description: "Sync Verbinal's data in VOSpace now, as Sync Now in Settings ▸ Storage does, and answer how it went (list_storage_kinds' answer). It brings to this Mac what another device kept — package lists, results, and the collections of their work the person keeps there — and sends this Mac's changes to those collections; it never deletes. Usually not needed: Verbinal syncs after sign-in by itself. Requires sign-in. Live-applied.",
        schema: #"{ "type": "object", "properties": {}, "additionalProperties": false }"#
    )

    let sync: @Sendable () async throws -> StorageSync.Status

    func handle(_ args: Args, context: AIToolContext) async throws -> StorageKindsOut {
        StorageKindsOut(try await sync())
    }
}
