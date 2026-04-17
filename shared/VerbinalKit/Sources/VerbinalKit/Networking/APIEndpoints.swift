// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

public struct APIEndpoints: Sendable {
    public var loginBaseURL: String
    public var skahaBaseURL: String
    public var acBaseURL: String
    public var storageBaseURL: String

    public init(
        loginBaseURL: String = "https://ws-cadc.canfar.net/ac",
        skahaBaseURL: String = "https://ws-uv.canfar.net/skaha",
        acBaseURL: String = "https://ws-uv.canfar.net/ac",
        storageBaseURL: String = "https://ws-uv.canfar.net/arc/nodes/home"
    ) {
        self.loginBaseURL = loginBaseURL
        self.skahaBaseURL = skahaBaseURL
        self.acBaseURL = acBaseURL
        self.storageBaseURL = storageBaseURL
    }

    public var loginURL: String { "\(loginBaseURL)/login" }
    public var whoAmIURL: String { "\(loginBaseURL)/whoami" }
    public func userURL(_ username: String) -> String { "\(loginBaseURL)/users/\(username)?idType=HTTP&detail=display" }

    public var sessionsURL: String { "\(skahaBaseURL)/v1/session" }
    public func sessionURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)" }
    public func sessionRenewURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)?action=renew" }
    public func sessionEventsURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)?view=events" }
    public func sessionLogsURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)?view=logs" }
    public var statsURL: String { "\(skahaBaseURL)/v1/session?view=stats" }

    public var imagesURL: String { "\(skahaBaseURL)/v1/image" }
    public var contextURL: String { "\(skahaBaseURL)/v1/context" }
    public var repositoryURL: String { "\(skahaBaseURL)/v1/repository" }

    public func storageURL(_ username: String) -> String { "\(storageBaseURL)/\(username)?limit=0" }
}
