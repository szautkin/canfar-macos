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

struct APIEndpoints {
    var loginBaseURL = "https://ws-cadc.canfar.net/ac"
    var skahaBaseURL = "https://ws-uv.canfar.net/skaha"
    var acBaseURL = "https://ws-uv.canfar.net/ac"
    var storageBaseURL = "https://ws-uv.canfar.net/arc/nodes/home"

    var loginURL: String { "\(loginBaseURL)/login" }
    var whoAmIURL: String { "\(loginBaseURL)/whoami" }
    func userURL(_ username: String) -> String { "\(acBaseURL)/users/\(username)" }

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
