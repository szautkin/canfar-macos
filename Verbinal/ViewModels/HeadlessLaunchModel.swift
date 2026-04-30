// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Owns the state and launch action for the Headless tab on the
/// dashboard's launch form. Distinct from `SessionLaunchModel` because
/// the user-visible surface is meaningfully different (cmd / args /
/// replicas instead of session-type) and the launch path goes through
/// `HeadlessService`, not `SessionService`.
///
/// The image catalogue is borrowed read-only from the parent
/// `SessionLaunchModel.images(forType: "headless")` — single fetch,
/// shared across both tabs.
@Observable
@MainActor
final class HeadlessLaunchModel {
    private let headlessService: HeadlessService
    private let recentLaunchStore: RecentLaunchStore

    // MARK: - Form state

    var sessionName: String = ""
    var selectedProject: String = ""
    var selectedImage: ParsedImage?
    var cmd: String = ""
    var args: String = ""
    var replicas: Int = 1
    var resourceType: String = "flexible" // "flexible" or "fixed"
    var cores: Int = 2
    var ram: Int = 8
    var gpus: Int = 0

    // MARK: - Status

    var isLaunching: Bool = false
    var hasError: Bool = false
    var errorMessage: String = ""
    var launchSuccess: Bool = false
    var launchStatus: String = ""
    /// Session ids returned by the most recent launch. May be partial
    /// after a `partialReplicaFailure` — `errorMessage` will explain.
    private(set) var lastLaunchedJobIDs: [String] = []

    init(headlessService: HeadlessService, recentLaunchStore: RecentLaunchStore) {
        self.headlessService = headlessService
        self.recentLaunchStore = recentLaunchStore
    }

    // MARK: - Validation

    var canLaunch: Bool {
        !isLaunching &&
        !sessionName.trimmingCharacters(in: .whitespaces).isEmpty &&
        selectedImage != nil &&
        !cmd.trimmingCharacters(in: .whitespaces).isEmpty &&
        replicas >= 1
    }

    // MARK: - Launch

    func launch() async {
        let trimmedName = sessionName.trimmingCharacters(in: .whitespaces)
        let trimmedCmd = cmd.trimmingCharacters(in: .whitespaces)
        let trimmedArgs = args.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            hasError = true
            errorMessage = String(localized: "Job name is required")
            return
        }
        guard let image = selectedImage else {
            hasError = true
            errorMessage = String(localized: "Please select an image")
            return
        }
        guard !trimmedCmd.isEmpty else {
            hasError = true
            errorMessage = String(localized: "Command is required")
            return
        }
        guard replicas >= 1 else {
            hasError = true
            errorMessage = String(localized: "Replicas must be at least 1")
            return
        }

        isLaunching = true
        launchSuccess = false
        hasError = false
        launchStatus = String(localized: "Launching headless job…")

        let isFixed = resourceType == "fixed"
        let params = HeadlessLaunchParams(
            name: trimmedName,
            image: image.id,
            cmd: trimmedCmd,
            args: trimmedArgs.isEmpty ? nil : trimmedArgs,
            env: [],
            cores: isFixed ? cores : nil,
            ram:   isFixed ? ram   : nil,
            gpus:  isFixed && gpus > 0 ? gpus : nil,
            replicas: replicas
        )

        do {
            let ids = try await headlessService.launchHeadlessJob(params)
            lastLaunchedJobIDs = ids
            launchSuccess = true
            launchStatus = ids.count == 1
                ? String(localized: "Headless job launched (id=\(ids[0]))")
                : String(localized: "\(ids.count) headless replicas launched")
            persistRecentLaunches(ids: ids, params: params, image: image)
        } catch let HeadlessLaunchError.partialReplicaFailure(launchedIDs, failedIdx, message) {
            lastLaunchedJobIDs = launchedIDs
            hasError = true
            errorMessage = String(
                localized: "Replica \(failedIdx + 1) failed: \(message). \(launchedIDs.count) replicas already running."
            )
            launchStatus = String(localized: "Partial launch — see error below")
            persistRecentLaunches(ids: launchedIDs, params: params, image: image)
        } catch HeadlessLaunchError.emptyResponse {
            hasError = true
            errorMessage = String(localized: "Skaha returned an empty response.")
            launchStatus = String(localized: "Launch failed")
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
            launchStatus = String(localized: "Launch failed")
        }

        isLaunching = false
    }

    // MARK: - Reset

    func resetForm() {
        sessionName = ""
        cmd = ""
        args = ""
        replicas = 1
        // Keep selectedProject / selectedImage — typical user pattern is
        // launching the same image with different cmds.
        hasError = false
        errorMessage = ""
        launchSuccess = false
        launchStatus = ""
    }

    // MARK: - Recent launches

    private func persistRecentLaunches(
        ids: [String],
        params: HeadlessLaunchParams,
        image: ParsedImage
    ) {
        // One RecentLaunch entry per replica so the dashboard's
        // "Recent Launches" surface shows them individually with their
        // own ids. Headless launches use the type "headless".
        for (idx, _) in ids.enumerated() {
            let displayName = ids.count == 1
                ? params.name
                : "\(params.name)-\(idx + 1)"
            let launch = RecentLaunch(
                name: displayName,
                type: "headless",
                image: image.id,
                imageLabel: image.label,
                project: selectedProject,
                resourceType: params.cores != nil ? "fixed" : "flexible",
                cores: params.cores ?? 0,
                ram: params.ram ?? 0,
                gpus: params.gpus ?? 0,
                launchedAt: Date()
            )
            recentLaunchStore.save(launch)
        }
    }
}
