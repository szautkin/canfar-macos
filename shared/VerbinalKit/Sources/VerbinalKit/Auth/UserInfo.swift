// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

public struct UserInfo: Codable, Sendable, Equatable {
    public let username: String
    public let email: String?
    public let firstName: String?
    public let lastName: String?
    public let institute: String?
    public let internalID: String?

    public init(
        username: String,
        email: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        institute: String? = nil,
        internalID: String? = nil
    ) {
        self.username = username
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.institute = institute
        self.internalID = internalID
    }
}
