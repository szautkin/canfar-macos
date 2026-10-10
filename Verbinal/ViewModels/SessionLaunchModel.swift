// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Resources asked of the launch form from outside it — an assistant's
/// show_launch_form (plan 30 T5): Flexible or Fixed, and the fixed size.
struct LaunchResources: Equatable, Sendable {
    /// "flexible" or "fixed".
    var type: String?
    var cores: Int?
    /// GB.
    var ram: Int?
    var gpus: Int?

    var asksForASize: Bool { cores != nil || ram != nil || gpus != nil }
    /// A size given is a fixed one.
    var resolvedType: String? { asksForASize ? "fixed" : type }
}

@Observable
@MainActor
final class SessionLaunchModel {
    private let sessionService: any SessionLaunching
    private let imageService: ImageService
    let recentLaunchStore: RecentLaunchStore
    let cacheService: PortalImageCacheService?
    let settingsService: PortalSettingsService?
    let username: String

    private var imagesByTypeAndProject: [String: [String: [ParsedImage]]] = [:]
    private let userImages: UserImageStore?
    private let tasks: TaskRegistry
    private let launches: SessionLaunches
    private var cachedImages: [RawImage] = []

    /// Shared accessor for the parsed image catalogue, keyed by session
    /// type. Non-headless tabs already drive their own picker via
    /// `images` / `projects` after `selectedType` changes; this lets
    /// the parallel Headless launch tab read its slice without
    /// re-fetching the catalogue.
    func images(forType type: String) -> [String: [ParsedImage]] {
        imagesByTypeAndProject[type] ?? [:]
    }

    // Default images per session type
    private static let defaultImageNames: [String: String] = [
        "notebook": "astroml:latest",
        "desktop": "desktop:latest",
        "carta": "carta:latest",
        "contributed": "astroml-vscode:latest",
        "firefly": "firefly:2025.2"
    ]

    // Form state
    var selectedType = "notebook" {
        didSet { if oldValue != selectedType { onTypeChanged(); recomputeDefaultFlags() } }
    }
    var selectedProject = "" {
        didSet { if oldValue != selectedProject { onProjectChanged() } }
    }
    var selectedImage: ParsedImage?
    var sessionName = ""
    var resourceType = "flexible" { // "flexible" or "fixed"
        didSet { if oldValue != resourceType { recomputeDefaultFlags() } }
    }
    var cores = 2 {
        didSet { if oldValue != cores { recomputeDefaultFlags() } }
    }
    var ram = 8 {
        didSet { if oldValue != ram { recomputeDefaultFlags() } }
    }
    var gpus = 0 {
        didSet { if oldValue != gpus { recomputeDefaultFlags() } }
    }

    // Advanced mode
    var useCustomImage = false
    var customImageUrl = ""
    var repositoryHost = "" {
        didSet { if oldValue != repositoryHost { onRegistryChanged() } }
    }
    var repositoryUsername = ""
    var repositorySecret = ""

    // Options from API
    var sessionTypes: [String] = ["notebook", "desktop", "carta", "contributed", "firefly"]
    var projects: [String] = []
    var images: [ParsedImage] = []
    var coreOptions: [Int] = []
    var ramOptions: [Int] = []
    var gpuOptions: [Int] = []
    var repositories: [String] = []
    var defaultCores = 2
    var defaultRam = 8

    // Status
    var isLoading = false
    var isLaunching = false
    var launchStatus = ""
    var launchSuccess = false
    var errorMessage = ""
    var hasError = false
    var isAtSessionLimit = false
    var sessionLimitMessage = ""
    let maxConcurrentSessions = 3

    // Recent launch collision
    var pendingRecentLaunch: RecentLaunch?
    var showRecentLaunchConflict = false

    // Callbacks to query session state from SessionListModel
    var sessionCounter: ((String) -> Int)?
    var totalSessionCounter: (() -> Int)?
    var sessionNamesForType: ((String) -> [String])?

    init(sessionService: any SessionLaunching,
         imageService: ImageService,
         recentLaunchStore: RecentLaunchStore,
         cacheService: PortalImageCacheService? = nil,
         settingsService: PortalSettingsService? = nil,
         userImages: UserImageStore? = nil,
         username: String = "",
         tasks: TaskRegistry = .shared) {
        self.sessionService = sessionService
        self.imageService = imageService
        self.recentLaunchStore = recentLaunchStore
        self.cacheService = cacheService
        self.settingsService = settingsService
        self.userImages = userImages
        self.username = username
        self.tasks = tasks
        self.launches = SessionLaunches(service: sessionService, tasks: tasks)
        recomputeDefaultFlags()
    }

    // MARK: - Load Data

    /// Loads images + context + repositories through the cache service (when present).
    /// Returns cached data immediately and kicks off a background refresh if stale.
    func loadImagesAndContext() async {
        isLoading = true
        hasError = false

        do {
            if let cacheService, !username.isEmpty {
                let (cache, wasCached) = try await cacheService.loadOrFetch(
                    username: username,
                    imageService: imageService
                )
                apply(cache: cache)
                applyDefaults()
                isLoading = false

                // Stale-while-revalidate: background refresh if the cached data is too old.
                if wasCached && cacheService.isStale {
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            let fresh = try await cacheService.fetchFresh(
                                username: self.username,
                                imageService: self.imageService
                            )
                            self.apply(cache: fresh)
                            self.applyDefaults()
                        } catch {
                            // Silent — we already have the stale data visible
                        }
                    }
                }
            } else {
                // Fallback path for tests / legacy callers without a cache service.
                async let rawImagesTask = imageService.getImages()
                async let contextTask = imageService.getContext()
                async let reposTask = imageService.getRepositories()

                let rawImages = try await rawImagesTask
                let context = try await contextTask
                let repos = (try? await reposTask) ?? []

                let cache = PortalImageCache(
                    username: username,
                    images: rawImages,
                    context: context,
                    repositories: repos,
                    fetchedAt: Date()
                )
                apply(cache: cache)
                applyDefaults()
                isLoading = false
            }
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Force a fresh network fetch, bypassing the cache TTL.
    func refreshImages() async {
        guard let cacheService, !username.isEmpty else { return }
        isLoading = true
        hasError = false
        do {
            let fresh = try await cacheService.fetchFresh(
                username: username,
                imageService: imageService
            )
            apply(cache: fresh)
            applyDefaults()
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func apply(cache: PortalImageCache) {
        // The images the person added join the catalogue here, not in the
        // cache, so taking one out shows without waiting for a refresh.
        cachedImages = userImages?.merged(into: cache.images) ?? cache.images
        imagesByTypeAndProject = ImageParser.groupByTypeAndProject(cachedImages)
        repositories = cache.repositories

        if repositoryHost.isEmpty, let first = cache.repositories.first {
            repositoryHost = first
        }

        if let context = cache.context {
            coreOptions = context.cores.options
            ramOptions = context.memoryGB.options
            gpuOptions = context.gpus.options
            defaultCores = context.cores.default
            defaultRam = context.memoryGB.default
            cores = defaultCores
            ram = defaultRam
        }

        rebuildFilteredImages()
        generateSessionName()
    }

    /// Apply the user's saved Portal defaults on top of the freshly-loaded data.
    /// Silently falls through if the saved default no longer exists in the current list.
    private func applyDefaults() {
        guard let settings = settingsService?.settings(for: username) else { return }

        // Default session type → triggers the cascade via didSet
        if let type = settings.defaultSessionType,
           sessionTypes.contains(type),
           selectedType != type {
            selectedType = type
        }

        // Default project (projects is now populated for the current session type)
        if let project = settings.defaultProject,
           projects.contains(project),
           selectedProject != project {
            selectedProject = project
        }

        // Default container image (images list now reflects the chosen project)
        if let imageID = settings.defaultContainerImageID,
           let match = images.first(where: { $0.id == imageID }) {
            selectedImage = match
        }

        // Default resources (falls back to context defaults if saved values are out of range)
        if let type = settings.defaultResourceType {
            resourceType = type
            if type == "fixed" {
                if let c = settings.defaultCores, coreOptions.contains(c) { cores = c }
                if let r = settings.defaultRam, ramOptions.contains(r) { ram = r }
                if let g = settings.defaultGpus, gpuOptions.contains(g) { gpus = g }
            }
        }
    }

    /// Cached "current selection matches saved default" flags.
    ///
    /// Recomputed eagerly via ``recomputeDefaultFlags()`` whenever an input
    /// changes (session type / resource type / cores / ram / gpus, through
    /// their `didSet`) or the saved defaults are toggled — instead of
    /// re-reading `settingsService.settings(for:)` on every SwiftUI body
    /// evaluation (ticket 059). Exposed read-only so views observe a plain
    /// stored property and nothing mutates model state during rendering.
    var isSelectedSessionTypeDefault = false
    var isSelectedResourcesDefault = false
    // MARK: - Cascading Selection

    private func onRegistryChanged() {
        rebuildFilteredImages()
    }

    private func onTypeChanged() {
        updateProjects()
        updateImages()
        generateSessionName()
    }

    private func onProjectChanged() {
        updateImages()
    }

    /// Re-filters cached images by the selected registry and rebuilds the cascade.
    private func rebuildFilteredImages() {
        let filtered: [RawImage]
        if repositoryHost.isEmpty {
            filtered = cachedImages
        } else {
            filtered = cachedImages.filter { rawImage in
                let registry = rawImage.id.split(separator: "/").first.map(String.init) ?? ""
                return registry == repositoryHost
            }
        }

        imagesByTypeAndProject = ImageParser.groupByTypeAndProject(filtered)

        let excludedTypes: Set<String> = ["headless", "desktop-app"]
        let availableTypes = Array(Set(imagesByTypeAndProject.keys))
            .filter { !excludedTypes.contains($0) }
            .sorted()
        if !availableTypes.isEmpty {
            sessionTypes = availableTypes
        }

        if !sessionTypes.contains(selectedType) {
            selectedType = sessionTypes.first ?? "notebook"
        }
        onTypeChanged()
    }

    private func updateProjects() {
        let typeKey = selectedType.lowercased()
        guard let projectMap = imagesByTypeAndProject[typeKey] else {
            projects = []
            images = []
            selectedImage = nil
            return
        }

        projects = Array(projectMap.keys).sorted()

        // Try to find the project containing the default image
        if let defaultProject = findProjectWithDefaultImage() {
            selectedProject = defaultProject
        } else if let first = projects.first {
            selectedProject = first
        }
    }

    private func updateImages() {
        let typeKey = selectedType.lowercased()
        guard let projectMap = imagesByTypeAndProject[typeKey],
              let imageList = projectMap[selectedProject] else {
            images = []
            selectedImage = nil
            return
        }

        images = imageList

        // Try to select the default image
        if let defaultImg = trySelectDefaultImage() {
            selectedImage = defaultImg
        } else {
            selectedImage = images.first
        }
    }

    private func findProjectWithDefaultImage() -> String? {
        let typeKey = selectedType.lowercased()
        guard let defaultName = Self.defaultImageNames[typeKey],
              let projectMap = imagesByTypeAndProject[typeKey] else {
            return nil
        }

        for (project, imgs) in projectMap {
            if imgs.contains(where: { $0.label == defaultName || $0.id.hasSuffix(defaultName) }) {
                return project
            }
        }
        return nil
    }

    private func trySelectDefaultImage() -> ParsedImage? {
        let typeKey = selectedType.lowercased()
        guard let defaultName = Self.defaultImageNames[typeKey] else { return nil }

        // Try exact label match, then ID suffix match
        return images.first(where: { $0.label == defaultName })
            ?? images.first(where: { $0.id.hasSuffix(defaultName) })
    }

    // MARK: - Launch

    /// The Advanced tab's image as a launch asks for it: under the chosen
    /// registry, unless it already names a registry — its first part a
    /// host (a dot, a port, or localhost), as a pasted or agent-given full
    /// reference does.
    nonisolated static func customImageReference(_ image: String, host: String) -> String {
        let first = image.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let namesRegistry = image.contains("/") && (first.contains(".") || first.contains(":") || first == "localhost")
        return host.isEmpty || namesRegistry ? image : "\(host)/\(image)"
    }

    func launch() async {
        // errorMessage + launchStatus are displayed via `Text(model.errorMessage)`
        // (verbatim String initializer) — localize at assignment to keep the
        // surface type `String` while still routing through the catalog.
        guard !sessionName.isEmpty else {
            hasError = true
            errorMessage = String(localized: "Session name is required")
            return
        }

        let imageId: String
        if useCustomImage {
            let trimmed = RegistryImage.normalized(customImageUrl)
            guard !trimmed.isEmpty else {
                hasError = true
                errorMessage = String(localized: "Custom image URL is required")
                return
            }
            // Allow only characters that are legal in container image references:
            // lowercase alphanumerics, digits, "-", ".", "_", ":", "/". Reject path
            // traversal, whitespace, and shell metacharacters before string-interpolating.
            let imageRefPattern = #"^[A-Za-z0-9][A-Za-z0-9._/:@-]*$"#
            guard trimmed.range(of: imageRefPattern, options: .regularExpression) != nil,
                  !trimmed.contains("..") else {
                hasError = true
                errorMessage = String(localized: "Custom image URL contains invalid characters")
                return
            }
            imageId = Self.customImageReference(trimmed, host: repositoryHost)
        } else {
            guard let img = selectedImage else {
                hasError = true
                errorMessage = String(localized: "Please select an image")
                return
            }
            imageId = img.id
        }

        isLaunching = true
        launchSuccess = false
        hasError = false
        launchStatus = String(localized: "Launching session…")

        var params = SessionLaunchParams(
            type: selectedType,
            name: sessionName,
            image: imageId
        )

        if resourceType == "fixed" {
            params.cores = cores
            params.ram = ram
            params.gpus = gpus
        } else {
            params.cores = 0
            params.ram = 0
            params.gpus = 0
        }

        if useCustomImage && !repositoryUsername.isEmpty {
            params.registryUsername = repositoryUsername
            params.registrySecret = repositorySecret
        }

        do {
            // On the activity bar, as every launch is (SessionLaunches).
            let sessionId = try await launches.launch(params).id
            launchSuccess = true
            launchStatus = String(localized: "Session launched! ID: \(sessionId)")

            // Hold pending entry — saved when user closes the progress sheet
            pendingRecentLaunch = RecentLaunch(
                name: sessionName,
                type: selectedType,
                image: imageId,
                imageLabel: selectedImage?.label ?? customImageUrl,
                project: selectedProject,
                resourceType: resourceType,
                cores: params.cores,
                ram: params.ram,
                gpus: params.gpus,
                launchedAt: Date()
            )

            // Reset form
            generateSessionName()
        } catch {
            // A launch with no session ID is a failure too (LaunchedWithoutID):
            // no "unknown" RecentLaunch is stored.
            hasError = true
            errorMessage = error.localizedDescription
            launchStatus = String(localized: "Launch failed")
        }

        isLaunching = false
    }

    /// Relaunches with parameters from a recent launch.
    func relaunch(_ launch: RecentLaunch) async -> Bool {
        isLaunching = true
        launchSuccess = false
        hasError = false
        launchStatus = String(localized: "Relaunching session…")

        var params = SessionLaunchParams(
            type: launch.type,
            name: launch.name,
            image: launch.image
        )

        if launch.resourceType == "fixed" {
            params.cores = launch.cores
            params.ram = launch.ram
            params.gpus = launch.gpus
        }

        do {
            _ = try await launches.launch(params)
            launchSuccess = true
            launchStatus = String(localized: "Session relaunched!")

            var updated = launch
            updated.launchedAt = Date()
            recentLaunchStore.save(updated)
            isLaunching = false
            return true
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
            launchStatus = String(localized: "Relaunch failed")
            isLaunching = false
            return false
        }
    }
}
