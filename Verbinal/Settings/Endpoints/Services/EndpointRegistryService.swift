// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import VerbinalKit

/// Resolves the app's service endpoints from the IVOA registry and caches
/// the result on disk.
///
/// Resolution never blocks or degrades the running app:
///  • `AppState.initialize()` fires `refreshIfStale()` as a detached task
///    BEFORE the auth check — launch always proceeds on override/cache/
///    default values.
///  • A failed refresh (offline, registry down, garbage response) keeps
///    the previous cache untouched and surfaces only as `refreshState =
///    .failed(…)` in the Endpoints settings tab.
///  • Services capture `APIEndpoints` by value at launch, so a resolution
///    that changes an effective endpoint flips
///    `resolvedChangesPendingRelaunch` (restart banner) rather than
///    hot-swapping URLs under live requests.
///
/// Only the services the app actually talks to are resolved (gms, skaha,
/// arc, argus, caom2ops, resolver, data); the per-field precedence is
/// user override > cached resolution > hardcoded CANFAR default.
@MainActor
@Observable
final class EndpointRegistryService {

    enum RefreshState: Equatable {
        case idle
        case refreshing
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "EndpointRegistry")
    private static let vospaceNodesStandardID = "ivo://ivoa.net/std/VOSpace/v2.0#nodes"

    /// CADC archive services share one host root; each entry maps the
    /// resource ID to the path suffix its service root carries, so the
    /// common `archiveBaseURL` can be recovered from any of them.
    private static let archiveServices: [(id: String, suffix: String)] = [
        ("ivo://cadc.nrc.ca/argus", "/argus"),
        ("ivo://cadc.nrc.ca/caom2ops", "/caom2ops"),
        ("ivo://cadc.nrc.ca/resolver", "/cadc-target-resolver"),
        ("ivo://cadc.nrc.ca/data", "/data"),
    ]

    private let settings: EndpointSettingsService
    private let client: RegistryClient
    private let cacheURL: URL

    /// Last successful resolution (possibly loaded from disk).
    private(set) var cached: ResolvedEndpoints?
    private(set) var refreshState: RefreshState = .idle
    /// True when a fresh resolution moved an effective endpoint away from
    /// what the running services captured at launch.
    private(set) var resolvedChangesPendingRelaunch = false
    /// Endpoints the app actually launched with. Set once by AppState.
    var activeAtLaunch: APIEndpoints?

    init(
        settings: EndpointSettingsService,
        client: RegistryClient = RegistryClient(),
        cacheURL: URL = EndpointRegistryService.defaultCacheURL()
    ) {
        self.settings = settings
        self.client = client
        self.cacheURL = cacheURL
        // Synchronous load is fine at launch: this is one tiny local JSON
        // file, and effective endpoints must be known before services are
        // constructed.
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(ResolvedEndpoints.self, from: data) {
            self.cached = decoded
        }
    }

    nonisolated static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Verbinal", isDirectory: true)
            .appendingPathComponent("endpoint-cache.json", isDirectory: false)
    }

    // MARK: - Effective values

    /// A cache produced by a different registry must not apply — the user
    /// pointing the app at another registry invalidates old resolutions.
    private var applicableCache: ResolvedEndpoints? {
        guard let cached else { return nil }
        let registry = EndpointResolution.effectiveValue(
            for: .registryBaseURL, overrides: settings.overrides, resolved: nil
        )
        return cached.registryBaseURL == registry ? cached : nil
    }

    func effectiveEndpoints() -> APIEndpoints {
        EndpointResolution.effective(overrides: settings.overrides, resolved: applicableCache)
    }

    func effectiveValue(for field: EndpointField) -> String {
        EndpointResolution.effectiveValue(for: field, overrides: settings.overrides, resolved: applicableCache)
    }

    func source(for field: EndpointField) -> EndpointSource {
        EndpointResolution.source(for: field, overrides: settings.overrides, resolved: applicableCache)
    }

    // MARK: - Refresh

    /// Launch policy: hit the registry only when there's no usable cache
    /// or it is older than `maxAge`. "Refresh Now" bypasses this.
    func refreshIfStale(maxAge: TimeInterval = 24 * 3600) async {
        if let cache = applicableCache, Date().timeIntervalSince(cache.fetchedAt) < maxAge {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard refreshState != .refreshing else { return }
        refreshState = .refreshing

        let registry = EndpointResolution.effectiveValue(
            for: .registryBaseURL, overrides: settings.overrides, resolved: nil
        )

        let resourceCaps: [String: String]
        do {
            resourceCaps = try await client.fetchResourceCaps(from: "\(registry)/resource-caps")
        } catch {
            Self.logger.warning("resource-caps fetch failed: \(error.localizedDescription, privacy: .public)")
            refreshState = .failed("Could not reach the registry: \(error.localizedDescription)")
            return
        }

        // Fetch capabilities for every app-relevant service that the
        // registry lists. A per-service failure just leaves that service
        // out — the affected fields keep their cache/default values.
        var wantedIDs = Set(Self.archiveServices.map(\.id))
        for field in EndpointField.allCases {
            if let id = field.resourceID { wantedIDs.insert(id) }
        }

        let client = self.client
        let capabilitiesByID: [String: [RegistryClient.Capability]] = await withTaskGroup(
            of: (String, [RegistryClient.Capability])?.self
        ) { group in
            for id in wantedIDs {
                guard let capsURL = resourceCaps[id] else { continue }
                group.addTask {
                    do {
                        return (id, try await client.fetchCapabilities(at: capsURL))
                    } catch {
                        return nil
                    }
                }
            }
            var results: [String: [RegistryClient.Capability]] = [:]
            for await entry in group {
                if let (id, caps) = entry { results[id] = caps }
            }
            return results
        }

        guard !capabilitiesByID.isEmpty else {
            refreshState = .failed("The registry answered, but no service capabilities could be read.")
            return
        }

        var resolved = ResolvedEndpoints(fetchedAt: Date(), registryBaseURL: registry)

        for (id, caps) in capabilitiesByID {
            if let root = RegistryClient.serviceRoot(from: caps) {
                resolved.perService[id] = root
            }
        }

        // Simple one-service fields: the service root IS the base URL.
        if let root = resolved.perService["ivo://cadc.nrc.ca/gms"] {
            resolved.values[.loginBaseURL] = root
        }
        if let root = resolved.perService["ivo://cadc.nrc.ca/skaha"] {
            resolved.values[.skahaBaseURL] = root
        }

        // Storage: prefer the VOSpace #nodes accessURL (it already carries
        // the /nodes path); fall back to the arc service root.
        if let arcCaps = capabilitiesByID["ivo://cadc.nrc.ca/arc"] {
            if let nodes = RegistryClient.accessURL(for: Self.vospaceNodesStandardID, in: arcCaps) {
                let base = nodes.hasSuffix("/") ? String(nodes.dropLast()) : nodes
                resolved.values[.storageBaseURL] = base + "/home"
            } else if let root = resolved.perService["ivo://cadc.nrc.ca/arc"] {
                resolved.values[.storageBaseURL] = root + "/nodes/home"
            }
        }

        // Archive: every CADC archive service hangs off one host root.
        // Recover it from each resolved service by stripping the known
        // suffix; only accept the result if all resolved services agree —
        // a single `archiveBaseURL` cannot represent a split deployment.
        var archiveRoots = Set<String>()
        for service in Self.archiveServices {
            guard let root = resolved.perService[service.id] else { continue }
            if root.hasSuffix(service.suffix) {
                archiveRoots.insert(String(root.dropLast(service.suffix.count)))
            }
        }
        if archiveRoots.count == 1, let root = archiveRoots.first {
            resolved.values[.archiveBaseURL] = root
        } else if archiveRoots.count > 1 {
            resolved.warnings.append(
                "Archive services report different hosts (\(archiveRoots.sorted().joined(separator: ", "))) — keeping the configured archive base."
            )
        }

        // Partial success: keep prior roots/values for services the
        // registry didn't answer this round (a flaky capabilities fetch
        // must not blank a previously-good cache entry).
        if let previous = cached, previous.registryBaseURL == registry {
            for (id, root) in previous.perService where resolved.perService[id] == nil {
                resolved.perService[id] = root
            }
            for (field, value) in previous.values where resolved.values[field] == nil {
                resolved.values[field] = value
            }
            if resolved.warnings.isEmpty, !previous.warnings.isEmpty {
                resolved.warnings = previous.warnings
            }
        }

        // Persist first, publish after — a crash between the two leaves
        // the previous cache intact rather than a half-applied state.
        do {
            let data = try JSONEncoder().encode(resolved)
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Self.logger.warning("endpoint cache write failed: \(error.localizedDescription, privacy: .public)")
        }

        cached = resolved
        refreshState = .idle
        if let active = activeAtLaunch {
            resolvedChangesPendingRelaunch = effectiveEndpoints() != active
        }
        Self.logger.info("Resolved \(resolved.perService.count, privacy: .public) services from \(registry, privacy: .public)")
    }
}
