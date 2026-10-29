// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Where the bearer token may go: the hosts of the endpoints in use, and
/// the classic CADC/CANFAR families.
extension NetworkClient {
    /// Default allow-list — the CADC + CANFAR domain families. Anything else
    /// (including DataLink redirects to partner archives) is treated as
    /// untrusted: requests still execute, but without our token.
    public static let defaultCADCHosts: [String] = [
        "cadc-ccda.hia-iha.nrc-cnrc.gc.ca",
        "canfar.net",
    ]

    /// Build the bearer-token host allow-list from effective endpoints,
    /// always unioned with the classic CADC/CANFAR families so a partial
    /// override cannot lock the app out of the defaults mid-session.
    public static func trustedHostSuffixes(from endpoints: APIEndpoints) -> [String] {
        var hosts = Set(defaultCADCHosts.map { $0.lowercased() })
        let urls = [
            endpoints.loginBaseURL, endpoints.skahaBaseURL, endpoints.acBaseURL,
            endpoints.storageBaseURL, endpoints.registryBaseURL,
            endpoints.archiveBaseURL, endpoints.externalBaseURL,
        ]
        for urlString in urls {
            if let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty {
                hosts.insert(host)
            }
        }
        return hosts.sorted()
    }

    /// Whether the bearer token would be attached to a request to `host`.
    /// Exposed for callers that need to decide whether to even make a call
    /// (e.g., authenticated endpoints).
    public func isTrustedAuthHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return trustedAuthHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }
}
