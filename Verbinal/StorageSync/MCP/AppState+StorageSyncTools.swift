// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Verbinal's data in VOSpace, for an assistant (plan 34 V).
extension AppState {
    /// Verbinal's data in VOSpace (plan 34 V), after a sync when asked.
    func storageSyncStatus(syncing: Bool) async throws -> StorageSync.Status {
        try requireSignInFor("Storage")
        if syncing, let paused = storageSync.status?.paused {
            // A pause is someone's choice: an ask to sync does not undo it (plan 40).
            let task = storageSync.taskID.map { " (activity task \($0))" } ?? ""
            throw ToolFailureReason.invalidArgument(
                "The storage sync is paused — by \(paused.by)\(paused.why.map { ", because: \($0)" } ?? "") — and stays paused until it is resumed: resume_activity\(task), or Resume in Settings ▸ Storage.")
        }
        if syncing {
            noteLive("sync_storage", "Synced Verbinal's data in storage")
            await storageSync.run(.asked)?.value
        } else if storageSync.status == nil {
            await storageSync.run(.cameBack)?.value
        }
        guard var status = storageSync.status else {
            throw ToolFailureReason.backendError("the storage sync has not started: sign in again")
        }
        status.progress = storageSync.current ?? status.progress
        status.activityTask = storageSync.taskID
        return status
    }

    /// The sync's conflicts, as Settings ▸ Storage shows them (plan 45).
    func syncConflicts() -> @Sendable () async throws -> [SyncConflict] {
        { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("app state gone") }
            return try await self.storageSyncStatus(syncing: false).conflicts
        }
    }

    /// Applies a choice the person approved, if it still means what it did
    /// when asked: a conflict found again since may do something else.
    func makeResolveSyncConflictApplier(activity: AgentActivityStore) -> ResolveSyncConflictApplier {
        ResolveSyncConflictApplier(resolve: { [weak self] payload in
            guard let self else { throw ProposalApplyError.backendError("app state gone") }
            try await MainActor.run { try self.requireSignInFor("Storage") }
            let task = try await MainActor.run { () throws -> Task<Void, Never>? in
                guard let conflict = self.storageSync.conflicts.first(where: { $0.id == payload.id }) else {
                    throw ProposalApplyError.backendError("the conflict \(payload.id) no longer waits: it was resolved, or found again — list_sync_conflicts")
                }
                guard conflict.removes(choosing: payload.choice) == payload.removes else {
                    throw ProposalApplyError.backendError("the conflict \(payload.id) changed since it was asked: list_sync_conflicts, and ask again")
                }
                return self.storageSync.resolve(payload.id, choosing: payload.choice)
            }
            await task?.value
        }, activity: activity)
    }
}
