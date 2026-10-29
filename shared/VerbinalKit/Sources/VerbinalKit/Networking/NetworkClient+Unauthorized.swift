// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A request CADC refused for its sign-in, asked about and sent again (plan 34 A).
extension NetworkClient {
    /// Restamp Authorization from the current token and retry `operation`
    /// once after the host's `onUnauthorized` handler refreshes credentials.
    /// Streaming PUT/GET bypass `execute`, so they share this helper instead
    /// of duplicating the 401 interceptor.
    func retryUnauthorized<T>(
        original request: URLRequest,
        allowAuthRetry: Bool = true,
        operation: (URLRequest) async throws -> T
    ) async throws -> T {
        var attempt: UnauthorizedAttempt? = allowAuthRetry ? .first : nil
        var current = request
        while true {
            do {
                return try await operation(current)
            } catch let error as NetworkError where error.isUnauthorized {
                guard let asked = attempt, let handler = onUnauthorized, await handler(asked) else { throw error }
                attempt = Self.next(after: asked)
                current = restamped(request)
            }
        }
    }

    /// The 401 after `attempt`'s retry: a second is asked about, a third is not.
    static func next(after attempt: UnauthorizedAttempt) -> UnauthorizedAttempt? {
        attempt == .first ? .again : nil
    }

    func restamped(_ request: URLRequest) -> URLRequest {
        var retried = request
        if let url = retried.url, isTrustedAuthHost(url.host),
           let token, !token.isEmpty {
            retried.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            retried.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return retried
    }
}
