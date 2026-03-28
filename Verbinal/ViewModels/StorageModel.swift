// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

@Observable
@MainActor
final class StorageModel {
    private let storageService: StorageService

    var isLoading = false
    var usedGB: Double = 0
    var quotaGB: Double = 0
    var usagePercent: Double = 0
    var isWarning = false
    var hasData = false
    var errorMessage = ""
    var hasError = false

    init(storageService: StorageService) {
        self.storageService = storageService
    }

    func loadQuota(username: String) async {
        isLoading = true
        hasError = false

        do {
            let quota = try await storageService.getQuota(username: username)
            usedGB = quota.usedGB
            quotaGB = quota.quotaGB
            usagePercent = quota.usagePercent
            isWarning = usagePercent > 90
            hasData = true
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
