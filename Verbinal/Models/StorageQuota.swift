// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct StorageQuota {
    var quotaBytes: Int64
    var usedBytes: Int64
    var lastModified: String?

    var quotaGB: Double { Double(quotaBytes) / 1_073_741_824.0 }
    var usedGB: Double { Double(usedBytes) / 1_073_741_824.0 }
    var usagePercent: Double {
        quotaBytes > 0 ? Double(usedBytes) / Double(quotaBytes) * 100.0 : 0
    }
}
