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
