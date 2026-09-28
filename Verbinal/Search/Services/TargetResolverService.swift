// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Service for resolving astronomical target names to coordinates.
/// Wraps TAPClient.resolveTarget with debouncing and caching.
actor TargetResolverService {
    private let tapClient: TAPClient
    private var cache: [String: ResolverResult] = [:]

    init(tapClient: TAPClient) {
        self.tapClient = tapClient
    }

    /// Resolve a target name, using cache when available. A transient
    /// designation that finds nothing is tried in the spellings the
    /// services know (``TransientName``); a miss says what was tried.
    func resolve(target: String, service: ResolverValue) async throws -> ResolverResult {
        let cacheKey = "\(target.lowercased())|\(service.rawValue)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let serviceName = service == .all ? "all" : service.rawValue.lowercased()
        let spellings = [target] + (TransientName(target)?.alternates(to: target) ?? [])
        var firstError: Error?
        for name in spellings {
            do {
                let result = try await tapClient.resolveTarget(name: name, service: serviceName)
                cache[cacheKey] = result
                return result
            } catch {
                firstError = firstError ?? error
            }
        }
        guard spellings.count > 1 else { throw firstError ?? SearchError.networkError("Target resolution failed") }
        throw SearchError.networkError(
            "\"\(target)\" was not found as \(spellings.map { "\"\($0)\"" }.joined(separator: ", ")) by NED, SIMBAD or VizieR")
    }

    func clearCache() {
        cache.removeAll()
    }
}
