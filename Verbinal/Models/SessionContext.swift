// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct SessionContext: Codable {
    let cores: ResourceOptions
    let memoryGB: ResourceOptions
    let gpus: GpuOptions
}

struct ResourceOptions: Codable {
    let `default`: Int
    let options: [Int]
}

struct GpuOptions: Codable {
    let options: [Int]
}
