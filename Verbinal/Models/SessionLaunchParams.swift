// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct SessionLaunchParams {
    var type: String = "notebook"
    var name: String = ""
    var image: String = ""
    var cores: Int = 2
    var ram: Int = 8
    var gpus: Int = 0
    var cmd: String?
    var registryUsername: String?
    var registrySecret: String?
}
