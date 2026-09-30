// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

extension AppState {
    /// A session's header: who connected to what, and the app's state then
    /// — the version and commit, macOS, the endpoints in use and which the
    /// person overrode, Auto-apply, the sign-in (plan 23 L2).
    func sessionLogHeader(_ session: UUID, _ client: String) -> SessionLogHeader {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let endpoints: [String: String] = [
            "login": self.endpoints.loginBaseURL, "skaha": self.endpoints.skahaBaseURL,
            "ac": self.endpoints.acBaseURL, "storage": self.endpoints.storageBaseURL,
            "registry": self.endpoints.registryBaseURL, "archive": self.endpoints.archiveBaseURL,
        ]
        return SessionLogHeader(
            session: session, client: client, opened: Date(), app: version,
            buildCommit: info?["VerbinalBuildCommit"] as? String,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            endpoints: endpoints,
            overridden: EndpointField.allCases.filter { endpointSettings.overrides[$0] != nil }.map(\.rawValue),
            autoApply: agentsService.autoApplyWrites, signedIn: isAuthenticated)
    }
}
