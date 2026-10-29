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
/// The registry is the source of truth (plan 53):
///  • Each URL the app calls is the access URL of the capability its service
///    publishes (`ServiceCapability`), not a root plus a fixed path.
///  • `AppState.initialize()` asks for a stale answer before the auth check
///    and waits for it briefly; a later answer applies when it lands.
///  • Every answer is applied live: `onChange` tells the app, which updates
///    the endpoints the services read on each request — no relaunch.
///  • A failed refresh (offline, registry down, garbage response) keeps
///    the previous cache untouched and surfaces only as `refreshState =
///    .failed(…)` in the Endpoints settings tab.
///
/// The per-field precedence is user override > cached resolution >
/// hardcoded CANFAR default.
@MainActor
@Observable
final class EndpointRegistryService {

    enum RefreshState: Equatable {
        case idle
        case refreshing
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "EndpointRegistry")

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
    /// Told when a refresh has an answer: the app applies it live.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// When the registry was last asked because a service was in trouble.
    @ObservationIgnored private var askedForTrouble: Date?
    /// A stale answer is asked for again after this long (plan 53 C1).
    nonisolated static let freshFor: TimeInterval = 6 * 3600
    /// A service in trouble asks the registry again at most this often (C3).
    nonisolated static let troubleAskEvery: TimeInterval = 5 * 60

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
        let base = AppSupport.directory
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
    func refreshIfStale(maxAge: TimeInterval = EndpointRegistryService.freshFor) async {
        if let cache = applicableCache, Date().timeIntervalSince(cache.fetchedAt) < maxAge {
            return
        }
        await refresh()
    }

    /// A service did not answer as it should (a 502 or 503, or no connection):
    /// it may have moved, so the registry is asked again — at most once in
    /// `troubleAskEvery` (plan 53 C3).
    func serviceInTrouble(now: Date = Date()) async {
        if let askedForTrouble, now.timeIntervalSince(askedForTrouble) < Self.troubleAskEvery { return }
        askedForTrouble = now
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
            resourceCaps = try await client.fetchResourceCaps(
                from: APIEndpoints(registryBaseURL: registry).resourceCapsURL)
        } catch {
            Self.logger.warning("resource-caps fetch failed: \(error.localizedDescription, privacy: .public)")
            refreshState = .failed("Could not reach the registry: \(error.localizedDescription)")
            return
        }

        // Fetch capabilities for every app-relevant service that the
        // registry lists. A per-service failure just leaves that service
        // out — the affected fields keep their cache/default values.
        var wantedIDs = Set(Self.archiveServices.map(\.id))
        wantedIDs.formUnion(ServiceCapability.allCases.map(\.resourceID))
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
        for field in [EndpointField.loginBaseURL, .acBaseURL, .skahaBaseURL] {
            if let id = field.resourceID, let root = resolved.perService[id] { resolved.values[field] = root }
        }

        // Each URL the app calls, as its service publishes it (plan 53 B).
        var published: [ServiceCapability: String] = [:]
        for capability in ServiceCapability.allCases {
            guard let caps = capabilitiesByID[capability.resourceID],
                  let url = RegistryClient.accessURL(for: capability.standardID, in: caps) else { continue }
            published[capability] = url.hasSuffix("/") ? String(url.dropLast()) : url
        }
        // Storage's nodes URL is the storage base below, not a URL of its own.
        let nodes = published.removeValue(forKey: .nodes)
        resolved.capabilities = published

        // Storage: prefer the VOSpace #nodes accessURL (it already carries
        // the /nodes path); fall back to the arc service root.
        if let nodes {
            resolved.values[.storageBaseURL] = nodes + "/home"
        } else if let root = resolved.perService[ServiceCapability.nodes.resourceID] {
            resolved.values[.storageBaseURL] = root + "/nodes/home"
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
            for (capability, url) in previous.capabilities ?? [:] where resolved.capabilities?[capability] == nil {
                resolved.capabilities?[capability] = url
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
        onChange?()
        Self.logger.info("Resolved \(resolved.perService.count, privacy: .public) services from \(registry, privacy: .public)")
    }
}
