// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

@Observable
@MainActor
final class StorageModel: PhaseOwner {
    private let storageService: StorageService

    /// Loading, loaded (when), or why not (plan 38); what loaded last stays.
    private(set) var load: Phase<Date> = .idle
    var usedGB: Double = 0
    var quotaGB: Double = 0
    var usagePercent: Double = 0
    var isWarning = false
    var hasData = false

    init(storageService: StorageService) {
        self.storageService = storageService
    }

    /// Whose quota it is, for Try Again.
    private var username = ""

    func reload() async {
        guard !username.isEmpty else { return }
        await loadQuota(username: username)
    }

    func loadQuota(username: String) async {
        self.username = username
        await run(\.load) {
            let quota = try await storageService.getQuota(username: username)
            usedGB = quota.usedGB
            quotaGB = quota.quotaGB
            usagePercent = quota.usagePercent
            isWarning = usagePercent > 90
            hasData = true
            return Date()
        }
    }
}
