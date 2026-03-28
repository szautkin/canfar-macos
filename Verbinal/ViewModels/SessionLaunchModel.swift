// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import Observation

@Observable
@MainActor
final class SessionLaunchModel {
    private let sessionService: SessionService
    private let imageService: ImageService
    private let recentLaunchStore: RecentLaunchStore

    private var imagesByTypeAndProject: [String: [String: [ParsedImage]]] = [:]
    private var cachedImages: [RawImage] = []
    private var cacheTime: Date?
    private let cacheDuration: TimeInterval = 300 // 5 minutes

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
    var repositoryHost = ""
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

    init(sessionService: SessionService, imageService: ImageService, recentLaunchStore: RecentLaunchStore) {
        self.sessionService = sessionService
        self.imageService = imageService
        self.recentLaunchStore = recentLaunchStore
    }

    // MARK: - Load Data

    func loadImagesAndContext() async {
        isLoading = true
        hasError = false

        do {
            async let rawImagesTask = imageService.getImages()
            async let contextTask = imageService.getContext()
            async let reposTask = imageService.getRepositories()

            let rawImages = try await rawImagesTask
            let context = try await contextTask
            let repos = (try? await reposTask) ?? []

            cachedImages = rawImages
            cacheTime = Date()
            imagesByTypeAndProject = ImageParser.groupByTypeAndProject(rawImages)
            repositories = repos

            // Auto-select first registry
            if repositoryHost.isEmpty, let first = repos.first {
                repositoryHost = first
            }

            // Determine available session types from images (interactive only)
            let availableTypes = Array(Set(imagesByTypeAndProject.keys))
                .filter { $0 != "headless" }
                .sorted()
            if !availableTypes.isEmpty {
                sessionTypes = availableTypes
            }

            // Set resource options
            coreOptions = context.cores.options
            ramOptions = context.memoryGB.options
            gpuOptions = context.gpus.options
            defaultCores = context.cores.default
            defaultRam = context.memoryGB.default
            cores = defaultCores
            ram = defaultRam

            // Set initial type and cascade
            if !sessionTypes.contains(selectedType) {
                selectedType = sessionTypes.first ?? "notebook"
            }
            onTypeChanged()
            generateSessionName()
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Cascading Selection

    private func onTypeChanged() {
        updateProjects()
        generateSessionName()
    }

    private func onProjectChanged() {
        updateImages()
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
            ? "Session limit reached (\(total)/\(maxConcurrentSessions))"
            : ""
    }

    // MARK: - Launch

    func launch() async {
        guard !sessionName.isEmpty else {
            hasError = true
            errorMessage = "Session name is required"
            return
        }

        let imageId: String
        if useCustomImage {
            guard !customImageUrl.isEmpty else {
                hasError = true
                errorMessage = "Custom image URL is required"
                return
            }
            // Advanced tab: prepend selected registry host to custom image path
            if !repositoryHost.isEmpty {
                imageId = "\(repositoryHost)/\(customImageUrl)"
            } else {
                imageId = customImageUrl
            }
        } else {
            guard let img = selectedImage else {
                hasError = true
                errorMessage = "Please select an image"
                return
            }
            imageId = img.id
        }

        isLaunching = true
        launchSuccess = false
        hasError = false
        launchStatus = "Launching session..."

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
            launchSuccess = true
            launchStatus = "Session launched! ID: \(sessionId ?? "unknown")"

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
            hasError = true
            errorMessage = error.localizedDescription
            launchStatus = "Launch failed"
        }

        isLaunching = false
    }

    /// Relaunches with parameters from a recent launch.
    func relaunch(_ launch: RecentLaunch) async -> Bool {
        isLaunching = true
        launchSuccess = false
        hasError = false
        launchStatus = "Relaunching session..."

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
            launchStatus = "Session relaunched!"

            var updated = launch
            updated.launchedAt = Date()
            recentLaunchStore.save(updated)
            isLaunching = false
            return true
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
            launchStatus = "Relaunch failed"
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
