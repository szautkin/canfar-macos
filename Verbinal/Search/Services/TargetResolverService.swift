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

    /// Resolve a target name, using cache when available.
    func resolve(target: String, service: ResolverValue) async throws -> ResolverResult {
        let cacheKey = "\(target.lowercased())|\(service.rawValue)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let serviceName = service == .all ? "all" : service.rawValue.lowercased()
        let result = try await tapClient.resolveTarget(name: target, service: serviceName)
        cache[cacheKey] = result
        return result
    }

    func clearCache() {
        cache.removeAll()
    }
}
