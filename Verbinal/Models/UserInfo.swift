// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct UserInfo: Codable {
    let username: String
    let email: String?
    let firstName: String?
    let lastName: String?
    let institute: String?
    let internalID: String?
}
