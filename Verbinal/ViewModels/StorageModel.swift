// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
