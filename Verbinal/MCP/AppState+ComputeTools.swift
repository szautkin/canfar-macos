// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// AI remote compute: reading run output and the compute settings.
extension AppState {
    /// `run_code_output` reads the watcher's result file back over the
    /// ARC REST API — through the service, so the run is recorded as done.
    func makeRunCodeOutputTool() -> RunCodeOutputTool {
        RunCodeOutputTool(fetchOut: { [weak self] id in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            do {
                return try await self.remoteCompute.fetchOut(id)
            } catch RemoteComputeError.signedOut {
                throw ToolFailureReason.authRequired
            } catch let e as NetworkError {
                switch e {
                case .unauthorized, .httpError(401, _), .httpError(403, _):
                    throw ToolFailureReason.authRequired
                default:
                    throw ToolFailureReason.backendError("run_code_output read failed: \(e.localizedDescription)")
                }
            }
        })
    }

    func makeGetComputeStateTool() -> GetComputeStateTool {
        GetComputeStateTool(snapshot: { [weak self] in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            return try await self.remoteCompute.snapshot()
        })
    }

    func makeListComputeRunsTool() -> ListComputeRunsTool {
        ListComputeRunsTool(runs: { [weak self] in await self?.remoteCompute.runs.runs ?? [] })
    }

    func makeGetComputeConfigTool() -> GetComputeConfigTool {
        GetComputeConfigTool(snapshot: { [weak self] in
            guard let self else {
                return .init(isEnabled: false, image: "", cores: 0, ramGB: 0,
                             registryHost: "", registryUsername: "", hasRegistrySecret: false)
            }
            return await MainActor.run {
                let settings = self.aiComputeSettings.settings
                return GetComputeConfigTool.Output(
                    isEnabled: settings.isEnabled,
                    image: settings.image,
                    cores: settings.cores,
                    ramGB: settings.ram,
                    registryHost: settings.registryHost,
                    registryUsername: settings.username,
                    hasRegistrySecret: settings.hasSecret)
            }
        })
    }
}

// MARK: - The Remote Compute screen and Storage, for an agent

extension AppState {
    /// The Remote Compute screen as an agent reads it.
    func computeScreenView(message: String? = nil) -> ComputeScreenView {
        remoteComputeModel.view(shown: currentMode == .remoteCompute, message: message)
    }

    func makeGetComputeViewTool() -> GetComputeViewTool {
        GetComputeViewTool(view: { [weak self] in
            await self?.computeScreenView()
                ?? ComputeScreenView(shown: false, state: "unknown", tab: "run", selectedRun: nil,
                                     snippet: .init(language: "python", timeoutSeconds: RunCodeContract.defaultTimeoutSeconds, code: ""),
                                     message: "app state unavailable")
        })
    }

    func makeShowComputeRunTool() -> ShowComputeRunTool {
        ShowComputeRunTool(show: { [weak self] id in
            guard let self else { throw ToolFailureReason.backendError("app state unavailable") }
            return try await self.showComputeRun(id)
        })
    }

    func makeSetComputeSnippetTool() -> SetComputeSnippetTool {
        SetComputeSnippetTool(set: { [weak self] args in
            guard let self else { throw ToolFailureReason.backendError("app state unavailable") }
            return try await self.setComputeSnippet(args)
        })
    }

    func makeShowStorageFolderTool() -> ShowStorageFolderTool {
        ShowStorageFolderTool(show: { [weak self] folder in
            guard let self else { throw ToolFailureReason.backendError("app state unavailable") }
            return try await self.showStorageFolder(forAgent: folder)
        })
    }

    /// Selects a run — the newest when none is named — as a click would, and
    /// shows the screen.
    func showComputeRun(_ id: String?) async throws -> ComputeScreenView {
        try requireSignInFor("Remote Compute")
        let model = remoteComputeModel
        navigateTo(.remoteCompute)
        guard let run = id.flatMap(model.service.runs.find) ?? (id == nil ? model.runs.first : nil) else {
            return computeScreenView(message: id.map { "no run \($0) — see list_compute_runs" } ?? "nothing has run yet")
        }
        model.select(run.id)
        noteLive("show_compute_run", "Showed a compute run")
        await model.loadOutput()
        return computeScreenView()
    }

    /// Fills the Run code box and shows it; never runs it.
    func setComputeSnippet(_ args: SetComputeSnippetTool.Args) throws -> ComputeScreenView {
        try requireSignInFor("Remote Compute")
        let model = remoteComputeModel
        model.setSnippet(code: args.code, language: (args.language ?? "python").lowercased(),
                         timeoutSeconds: args.timeoutSeconds ?? RunCodeContract.defaultTimeoutSeconds)
        navigateTo(.remoteCompute)
        noteLive("set_compute_snippet", "Put code in the Run code box")
        return computeScreenView(message: model.isConfigured
            ? nil : "remote compute is not set up, so the person sees the setup steps rather than the box")
    }

    /// Opens Storage at a folder of the person's own home.
    func showStorageFolder(forAgent folder: String) throws -> StorageFolderShown {
        try requireSignInFor("Storage")
        guard let path = ShowStorageFolderTool.homeRelative(folder, username: username) else {
            throw ToolFailureReason.invalidArgument("'\(folder)' is not in \(username)'s home — read other areas with list_vospace_path")
        }
        showStorageFolder(path)
        noteLive("show_storage_folder", "Opened Storage at \(path.isEmpty ? "the home folder" : path)")
        return StorageFolderShown(shown: true, folder: path, message: nil)
    }

    private func requireSignInFor(_ screen: String) throws {
        guard isAuthenticated, !username.isEmpty else {
            throw ToolFailureReason.targetNotResolved("\(screen) needs the person signed in to CANFAR")
        }
    }

    private func noteLive(_ kind: String, _ summary: String) {
        agentsService.activityStore.append(.live(kind: kind, summary: summary, origin: .external(clientID: kind)))
    }
}
