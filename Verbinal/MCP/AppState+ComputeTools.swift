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
    /// ARC REST API. A 404 means "not produced yet" (the session is still
    /// provisioning/executing) → surface as nil so the tool reports
    /// `ready:false` rather than an error.
    func makeRunCodeOutputTool(service: VOSpaceBrowserService) -> RunCodeOutputTool {
        RunCodeOutputTool(fetchOut: { [weak self] path, maxBytes in
            guard let self else { throw ToolFailureReason.backendError("appState gone") }
            let username = await self.username
            guard !username.isEmpty else { throw ToolFailureReason.authRequired }
            do {
                let result = try await service.fetchBytes(
                    username: username, path: path, offset: 0, maxBytes: maxBytes)
                return result.data
            } catch let e as NetworkError {
                switch e {
                case .httpError(404, _):
                    return nil   // result not written yet
                case .unauthorized, .httpError(401, _), .httpError(403, _):
                    throw ToolFailureReason.authRequired
                default:
                    throw ToolFailureReason.backendError("run_code_output read failed: \(e.localizedDescription)")
                }
            }
        })
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
