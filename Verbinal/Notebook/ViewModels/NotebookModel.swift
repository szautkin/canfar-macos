// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Manages the Notebook module: Jupyter server lifecycle and WebView URL.
@Observable
@MainActor
final class NotebookModel {
    let jupyterService = JupyterService()

    var serverURL: URL?
    var isStarting = false
    var errorMessage: String?
    var isAvailable = false

    init() {
        isAvailable = PythonDiscovery.isJupyterAvailable
    }

    func startServer() async {
        isStarting = true
        errorMessage = nil

        do {
            let url = try await jupyterService.start()
            serverURL = url
        } catch {
            errorMessage = error.localizedDescription
        }

        isStarting = false
    }

    func stopServer() async {
        await jupyterService.stop()
        serverURL = nil
    }

    func restartServer() async {
        await stopServer()
        await startServer()
    }

    var isRunning: Bool { serverURL != nil }
}
