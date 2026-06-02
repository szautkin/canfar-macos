// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

@Observable
@MainActor
final class SessionLaunchModel {
    private let sessionService: any SessionLaunching
    private let imageService: ImageService
    private let recentLaunchStore: RecentLaunchStore
    private let cacheService: PortalImageCacheService?
    private let settingsService: PortalSettingsService?
    private let username: String

    private var imagesByTypeAndProject: [String: [String: [ParsedImage]]] = [:]
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
        didSet { if oldValue != selectedType { onTypeChanged() } }
    }
    var selectedProject = "" {
        didSet { if oldValue != selectedProject { onProjectChanged() } }
    }
    var selectedImage: ParsedImage?
    var sessionName = ""
    var resourceType = "flexible" // "flexible" or "fixed"
    var cores = 2
    var ram = 8
    var gpus = 0

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
         username: String = "") {
        self.sessionService = sessionService
        self.imageService = imageService
        self.recentLaunchStore = recentLaunchStore
        self.cacheService = cacheService
        self.settingsService = settingsService
        self.username = username
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
        cachedImages = cache.images
        imagesByTypeAndProject = ImageParser.groupByTypeAndProject(cache.images)
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

    // MARK: - Default management

    /// Toggle whether the current project selection is saved as the user's default.
    func toggleDefaultProject() {
        guard let settingsService, !username.isEmpty, !selectedProject.isEmpty else { return }
        let current = settingsService.settings(for: username)?.defaultProject
        let next = (current == selectedProject) ? nil : selectedProject
        settingsService.setDefaultProject(next, for: username)
    }

    /// Toggle whether the current image selection is saved as the user's default.
    func toggleDefaultImage() {
        guard let settingsService, !username.isEmpty, let img = selectedImage else { return }
        let current = settingsService.settings(for: username)?.defaultContainerImageID
        let next = (current == img.id) ? nil : img.id
        settingsService.setDefaultImage(next, for: username)
    }

    /// Toggle whether the current session type is saved as the user's default.
    func toggleDefaultSessionType() {
        guard let settingsService, !username.isEmpty else { return }
        let current = settingsService.settings(for: username)?.defaultSessionType
        let next = (current == selectedType) ? nil : selectedType
        settingsService.setDefaultSessionType(next, for: username)
    }

    var isSelectedProjectDefault: Bool {
        guard let settingsService, !username.isEmpty, !selectedProject.isEmpty else { return false }
        return settingsService.settings(for: username)?.defaultProject == selectedProject
    }

    var isSelectedImageDefault: Bool {
        guard let settingsService, !username.isEmpty, let img = selectedImage else { return false }
        return settingsService.settings(for: username)?.defaultContainerImageID == img.id
    }

    var isSelectedSessionTypeDefault: Bool {
        guard let settingsService, !username.isEmpty else { return false }
        return settingsService.settings(for: username)?.defaultSessionType == selectedType
    }

    /// True when the current resource selection matches the saved defaults.
    var isSelectedResourcesDefault: Bool {
        guard let settingsService, !username.isEmpty,
              let saved = settingsService.settings(for: username),
              let savedType = saved.defaultResourceType else { return false }
        guard savedType == resourceType else { return false }
        if savedType == "flexible" { return true }
        return saved.defaultCores == cores
            && saved.defaultRam == ram
            && saved.defaultGpus == gpus
    }

    /// Save (or clear) the current resource selection as the user's default.
    func toggleDefaultResources() {
        guard let settingsService, !username.isEmpty else { return }
        if isSelectedResourcesDefault {
            settingsService.setDefaultResources(
                resourceType: nil, cores: nil, ram: nil, gpus: nil,
                for: username
            )
        } else {
            settingsService.setDefaultResources(
                resourceType: resourceType,
                cores: resourceType == "fixed" ? cores : nil,
                ram: resourceType == "fixed" ? ram : nil,
                gpus: resourceType == "fixed" ? gpus : nil,
                for: username
            )
        }
    }

    private static let cacheAgeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// Relative description of when the image cache was last updated, e.g. "3h ago".
    var cacheAgeDescription: String? {
        guard let timestamp = cacheService?.cacheTimestamp else { return nil }
        return Self.cacheAgeFormatter.localizedString(for: timestamp, relativeTo: Date())
    }

    // MARK: - External image selection

    /// Drive the form's full type → project → image cascade from a
    /// single `ParsedImage`. Used by surfaces outside the form
    /// (Canfar Images widget, agent tools) so a click in those
    /// places lands on the same model state the user would reach
    /// by walking the pickers manually.
    ///
    /// Cascade order matters — assigning out of order leaves the
    /// model with mismatched lists (e.g. a `selectedImage` that
    /// isn't in the current `images` array because the project
    /// hasn't rebuilt yet). The `didSet` observers do all the
    /// repopulation work; we just trigger them in the right order.
    ///
    /// Resource sliders, session name, and other form state are
    /// preserved — only the image-identity fields change.
    func applyImageSelection(_ image: ParsedImage) {
        // Catalogue images bypass the advanced "custom image" mode.
        if useCustomImage { useCustomImage = false }

        // 1. Session type — first cascade step. Skip if the image
        // doesn't declare any types (cache-only fallback path).
        if let primary = image.types.first?.lowercased(),
           sessionTypes.contains(primary),
           selectedType != primary {
            selectedType = primary
        }

        // 2. Project — only assign if the rebuilt projects list
        // actually contains it; otherwise stay on whatever the
        // type cascade landed on.
        if projects.contains(image.project),
           selectedProject != image.project {
            selectedProject = image.project
        }

        // 3. Image — prefer the catalogue's instance so identity
        // matches what the picker enumerates. Fall back to the
        // passed-in value when the catalogue can't produce one
        // (e.g. cache-only browse during a Skaha catalogue
        // outage).
        selectedImage = images.first(where: { $0.id == image.id }) ?? image
    }

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

    // MARK: - Session Name

    func generateSessionName() {
        let existingNames = Set(sessionNamesForType?(selectedType) ?? [])
        var n = existingNames.count + 1
        // Find the next number that doesn't collide with an existing session
        while existingNames.contains("\(selectedType)\(n)") {
            n += 1
        }
        sessionName = "\(selectedType)\(n)"
    }

    /// Re-generates the name only if the user hasn't customised it.
    func refreshSessionNameIfNeeded() {
        guard isAutoGeneratedName else { return }
        generateSessionName()
    }

    private var isAutoGeneratedName: Bool {
        if sessionName.isEmpty { return true }
        for type in sessionTypes {
            if sessionName.hasPrefix(type),
               Int(String(sessionName.dropFirst(type.count))) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Recent Launch Save (after progress sheet dismissed)

    /// Call after the launch progress sheet is closed.
    /// Saves to recent launches, or asks for confirmation on name collision.
    func savePendingRecentLaunch() {
        guard let pending = pendingRecentLaunch else { return }
        if recentLaunchStore.contains(name: pending.name) {
            showRecentLaunchConflict = true
        } else {
            recentLaunchStore.save(pending)
            pendingRecentLaunch = nil
        }
    }

    func confirmRecentLaunchOverride() {
        if let pending = pendingRecentLaunch {
            recentLaunchStore.save(pending)
        }
        pendingRecentLaunch = nil
        showRecentLaunchConflict = false
    }

    func skipRecentLaunchSave() {
        pendingRecentLaunch = nil
        showRecentLaunchConflict = false
    }

    // MARK: - Session Limit

    func updateSessionLimit() {
        let total = totalSessionCounter?() ?? 0
        isAtSessionLimit = total >= maxConcurrentSessions
        sessionLimitMessage = isAtSessionLimit
            ? Self.sessionLimitMessage(total: total, max: maxConcurrentSessions)
            : ""
    }

    /// Build the "Session limit reached (N/M)" string.
    ///
    /// The view layer renders `Label(model.sessionLimitMessage, ...)` with a
    /// `String`, bypassing `LocalizedStringKey`, so the message is resolved
    /// here at assignment time. The counts are formatted as locale-aware
    /// number arguments (rather than interpolated raw `Int`s) so that the
    /// catalog string can reorder them per language and the digits follow the
    /// user's locale conventions.
    static func sessionLimitMessage(total: Int, max: Int) -> String {
        let current = total.formatted(.number)
        let limit = max.formatted(.number)
        return String(
            format: String(localized: "Session limit reached (%1$@/%2$@)"),
            current,
            limit
        )
    }

    // MARK: - Launch

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
            let trimmed = customImageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Advanced tab: prepend selected registry host to custom image path
            if !repositoryHost.isEmpty {
                imageId = "\(repositoryHost)/\(trimmed)"
            } else {
                imageId = trimmed
            }
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
            let sessionId = try await sessionService.launchSession(params)
            if let sessionId {
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
            } else {
                // Non-throwing call but no session ID — a server/contract
                // failure. Report it rather than claiming success and storing a
                // meaningless "unknown" RecentLaunch.
                hasError = true
                errorMessage = String(localized: "The server accepted the launch but returned no session ID.")
                launchStatus = String(localized: "Launch failed")
            }
        } catch {
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
            _ = try await sessionService.launchSession(params)
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

    /// Applies a recent launch's settings to the form.
    func applyRecentLaunch(_ launch: RecentLaunch) {
        selectedType = launch.type

        if launch.resourceType == "fixed" {
            resourceType = "fixed"
            cores = launch.cores
            ram = launch.ram
            gpus = launch.gpus
        } else {
            resourceType = "flexible"
        }

        // Try to find the image in standard list
        if let project = imagesByTypeAndProject[launch.type.lowercased()]?
            .first(where: { $0.value.contains(where: { $0.id == launch.image }) })?.key {
            selectedProject = project
            selectedImage = images.first(where: { $0.id == launch.image })
            useCustomImage = false
        } else {
            // Fall back to custom image
            useCustomImage = true
            customImageUrl = launch.image
        }

        sessionName = launch.name
    }
}
