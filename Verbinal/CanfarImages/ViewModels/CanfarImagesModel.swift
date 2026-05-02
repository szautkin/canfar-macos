// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Backing model for the Canfar Images dashboard widget.
///
/// Pure read-side display: never launches probes itself. The user
/// triggers discovery via the "Inspect" button on a row OR
/// "More inspection…" in the footer, both of which open the existing
/// `ImageDiscoverySheet` (no UX rework — the sheet does its job).
///
/// Inputs (all live, captured at construction time and refreshed on
/// `reload()`):
///   * Image catalogue from `ImageService` (≈ 110 entries for the
///     typical user).
///   * Last-known outcomes from the `ImageDiscoveryCoordinator`'s
///     manifest store — shown as discovered / failed / unknown
///     status pills.
///   * User's marked-default images per session type from
///     `PortalSettingsService`. Drives the Default tab.
///   * Recent launches from `RecentLaunchStore`. Drives the
///     Popular tab.
@Observable
@MainActor
final class CanfarImagesModel {

    // MARK: - Dependencies

    private let imageService: ImageService
    private let coordinator: ImageDiscoveryCoordinator?
    private let recentLaunchStore: RecentLaunchStore
    private let portalSettingsService: PortalSettingsService
    private let username: String

    // MARK: - State

    /// Selected tab. Default to `.default` so first-time users land
    /// on something curated rather than an empty Popular tab.
    var selectedTab: CanfarImagesTab = .default

    /// Search-bar text — substring filter applied within the tab.
    var searchText: String = ""

    /// All catalogue entries, parsed.
    private(set) var allImages: [ParsedImage] = []

    /// Manifest / failure state per image id, refreshed from the
    /// coordinator's cache. Never populated by this model — it
    /// only reads.
    private(set) var manifestsByID: [String: ImageManifest] = [:]
    private(set) var failureMessagesByID: [String: String] = [:]

    /// Image ids the user has marked as their default for some
    /// session type, plus the system fallbacks. Drives the Default
    /// tab.
    private(set) var defaultImageIDs: Set<String> = []

    /// Image ids that appear in `RecentLaunchStore` (most recent
    /// first). Drives the Popular tab + the row's "recently used"
    /// affordance.
    private(set) var recentImageIDsInOrder: [String] = []

    /// Loading flag for the initial catalogue fetch.
    private(set) var isLoading: Bool = false

    /// Last error surfaced to the widget's banner area.
    var bannerMessage: String?

    init(
        imageService: ImageService,
        coordinator: ImageDiscoveryCoordinator?,
        recentLaunchStore: RecentLaunchStore,
        portalSettingsService: PortalSettingsService,
        username: String
    ) {
        self.imageService = imageService
        self.coordinator = coordinator
        self.recentLaunchStore = recentLaunchStore
        self.portalSettingsService = portalSettingsService
        self.username = username
    }

    // MARK: - Lifecycle

    /// Single-shot bootstrap. Refresh re-uses this path.
    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // 1. Catalogue.
        do {
            let raw = try await imageService.getImages()
            allImages = raw.map(ImageParser.parse)
        } catch {
            bannerMessage = "Couldn't load image catalogue: \(error.localizedDescription)"
            return
        }

        // 2. Discovery cache (best effort — coordinator is auth-
        // scoped; nil before login).
        if let coordinator {
            await refreshDiscoveryStateFromCache(coordinator)
        }

        // 3. Defaults + recent launches.
        refreshDefaultIDs()
        refreshRecentIDs()
    }

    /// Pull the latest discovery outcomes from the coordinator —
    /// called whenever the user dismisses the modal so the widget
    /// reflects fresh manifests / failure clears without a full
    /// reload.
    func refreshFromCache() async {
        guard let coordinator else { return }
        await refreshDiscoveryStateFromCache(coordinator)
    }

    private func refreshDiscoveryStateFromCache(
        _ coordinator: ImageDiscoveryCoordinator
    ) async {
        var manifests: [String: ImageManifest] = [:]
        var failures: [String: String] = [:]
        for image in allImages {
            switch await coordinator.outcome(for: image.id) {
            case .success(let m)?:
                manifests[image.id] = m
            case .failure(_, _, let msg, _, _)?:
                failures[image.id] = msg
            case .none:
                break
            }
        }
        manifestsByID = manifests
        failureMessagesByID = failures
    }

    private func refreshDefaultIDs() {
        // Per-user default image, if set.
        let userDefault = portalSettingsService
            .settings(for: username)?
            .defaultContainerImageID
        // System fallback per session type — picks up the curated
        // "starter" image when the user hasn't marked their own.
        let fallbackNames = SessionLaunchModel.fallbackDefaultImageNames

        var ids: Set<String> = []
        if let userDefault { ids.insert(userDefault) }
        for image in allImages where fallbackNames.values.contains(image.label) {
            ids.insert(image.id)
        }
        defaultImageIDs = ids
    }

    private func refreshRecentIDs() {
        // Recent-launch store stores image ids verbatim (matches
        // catalogue ids when launches came from the in-app form;
        // also captures MCP-driven and headless-derived launches).
        var seen: Set<String> = []
        var ordered: [String] = []
        for launch in recentLaunchStore.launches {
            if seen.insert(launch.image).inserted {
                ordered.append(launch.image)
            }
        }
        recentImageIDsInOrder = ordered
    }

    // MARK: - Filtered output

    /// Rows the widget renders for the active tab and search text.
    /// Sorted to put discovered rows first within each tab so the
    /// user's eye lands on actionable content, then by label A→Z.
    var filteredRows: [CanfarImageRow] {
        let scoped = imagesForActiveTab()
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = needle.isEmpty
            ? scoped
            : scoped.filter { matches(needle, $0) }

        let rows = hits.map { image in
            CanfarImageRow(
                image: image,
                manifest: manifestsByID[image.id],
                failureMessage: failureMessagesByID[image.id],
                isUserDefault: defaultImageIDs.contains(image.id),
                isRecentlyLaunched: recentImageIDsInOrder.contains(image.id)
            )
        }

        return rows.sorted { lhs, rhs in
            // Discovered first, then failed, then unknown.
            if lhs.status != rhs.status {
                return statusOrder(lhs.status) < statusOrder(rhs.status)
            }
            return lhs.image.label.localizedCaseInsensitiveCompare(rhs.image.label) == .orderedAscending
        }
    }

    private func imagesForActiveTab() -> [ParsedImage] {
        switch selectedTab {
        case .default:
            return allImages.filter { defaultImageIDs.contains($0.id) }
        case .popular:
            // Preserve recent-order, intersect with current
            // catalogue to drop ids the user has lost access to.
            let knownByID = Dictionary(uniqueKeysWithValues: allImages.map { ($0.id, $0) })
            return recentImageIDsInOrder.compactMap { knownByID[$0] }
        case .notebook, .desktop, .carta, .firefly, .contributed, .headless:
            guard let key = selectedTab.sessionTypeKey else { return [] }
            return allImages.filter { $0.types.contains(key) }
        }
    }

    private func matches(_ needle: String, _ image: ParsedImage) -> Bool {
        image.label.lowercased().contains(needle) ||
        image.id.lowercased().contains(needle) ||
        image.project.lowercased().contains(needle)
    }

    private func statusOrder(_ s: CanfarImageRow.Status) -> Int {
        switch s {
        case .discovered: return 0
        case .failed: return 1
        case .unknown: return 2
        }
    }

    // MARK: - Counts (for tab badges, "N of M" header)

    /// How many images are visible under each tab. Cheap; recomputed
    /// on every property access via `filteredRows` derivation, but
    /// the tab strip only needs the *unfiltered* counts for badges.
    func count(for tab: CanfarImagesTab) -> Int {
        switch tab {
        case .default:
            return allImages.lazy.filter { self.defaultImageIDs.contains($0.id) }.count
        case .popular:
            let known = Set(allImages.map(\.id))
            return recentImageIDsInOrder.lazy.filter { known.contains($0) }.count
        case .notebook, .desktop, .carta, .firefly, .contributed, .headless:
            guard let key = tab.sessionTypeKey else { return 0 }
            return allImages.lazy.filter { $0.types.contains(key) }.count
        }
    }

    var totalCatalogueCount: Int { allImages.count }
    var discoveredCount: Int { manifestsByID.count }
}

// MARK: - SessionLaunchModel default-image bridge

extension SessionLaunchModel {
    /// Re-export of the private `defaultImageNames` keyed by session
    /// type, so the Canfar Images widget can include curated
    /// fallbacks on the Default tab when the user hasn't picked
    /// their own. Match-by-label is intentional — the curated names
    /// are tag-stripped (`astroml:latest`), and the catalogue's
    /// `label` is the same shape.
    static var fallbackDefaultImageNames: [String: String] {
        [
            "notebook": "astroml:latest",
            "desktop": "desktop:latest",
            "carta": "carta:latest",
            "contributed": "astroml-vscode:latest",
            "firefly": "firefly:2025.2"
        ]
    }
}
