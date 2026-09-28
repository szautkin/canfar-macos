// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct StorageQuota {
    var quotaBytes: Int64
    var usedBytes: Int64

    /// Decimal gigabytes — 10⁹ bytes — as Finder counts and as the quota is
    /// set: a 200 GB quota read 186.26 "GB" when this divided by 2³⁰ (QA M15).
    static let bytesPerGB = 1_000_000_000.0

    var quotaGB: Double { Double(quotaBytes) / Self.bytesPerGB }
    var usedGB: Double { Double(usedBytes) / Self.bytesPerGB }
    var usagePercent: Double {
        quotaBytes > 0 ? Double(usedBytes) / Double(quotaBytes) * 100.0 : 0
    }
}
