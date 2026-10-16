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
}
