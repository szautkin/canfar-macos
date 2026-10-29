// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A service not there, told to the host (plan 53 C3).
extension NetworkClient {
    /// Told when a CADC or CANFAR service is not there — a 502 or 503, or no
    /// connection to it — so the host can ask the registry whether it moved
    /// (plan 53 C3). It never holds the request.
    public typealias TroubleHandler = @Sendable (URL) async -> Void

    public func setServiceTroubleHandler(_ handler: TroubleHandler?) {
        self.onServiceTrouble = handler
    }

    /// Whether an answer says the service itself is not there, rather than
    /// something about what was asked (a 404 is usually the latter).
    static func isServiceTrouble(status: Int) -> Bool { status == 502 || status == 503 }

    static func isServiceTrouble(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(code)
    }

    func reportTrouble(at url: URL?) {
        guard let url, isTrustedAuthHost(url.host), let handler = onServiceTrouble else { return }
        Task { await handler(url) }
    }
}
