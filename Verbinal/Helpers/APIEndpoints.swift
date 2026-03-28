// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct APIEndpoints {
    var loginBaseURL = "https://ws-cadc.canfar.net/ac"
    var skahaBaseURL = "https://ws-uv.canfar.net/skaha"
    var acBaseURL = "https://ws-uv.canfar.net/ac"
    var storageBaseURL = "https://ws-uv.canfar.net/arc/nodes/home"

    var loginURL: String { "\(loginBaseURL)/login" }
    var whoAmIURL: String { "\(loginBaseURL)/whoami" }
    func userURL(_ username: String) -> String { "\(loginBaseURL)/users/\(username)?idType=HTTP&detail=display" }

    var sessionsURL: String { "\(skahaBaseURL)/v1/session" }
    func sessionURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)" }
    func sessionRenewURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)?action=renew" }
    func sessionEventsURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)?view=events" }
    func sessionLogsURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)?view=logs" }
    var statsURL: String { "\(skahaBaseURL)/v1/session?view=stats" }

    var imagesURL: String { "\(skahaBaseURL)/v1/image" }
    var contextURL: String { "\(skahaBaseURL)/v1/context" }
    var repositoryURL: String { "\(skahaBaseURL)/v1/repository" }

    func storageURL(_ username: String) -> String { "\(storageBaseURL)/\(username)?limit=0" }
}
