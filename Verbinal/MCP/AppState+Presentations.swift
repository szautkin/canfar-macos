// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

extension AppState {
    /// What an assistant may open by its name: the presentations that need
    /// nothing chosen first, each through its one owner (plan 30 T3). Those
    /// that need a choice open from their control or their tool —
    /// `show_launch_form`'s image, `show_cutout_editor`'s observation.
    func registerOpenablePresentations() {
        let presentations = UIPresentations.shared
        presentations.register(openable: .init(name: "Launch Session", screen: AppMode.portal.rawValue) { [weak self] in
            self?.launchFormPresented = true
        })
        presentations.register(openable: .init(name: "Image Content Discovery", screen: AppMode.portal.rawValue) { [weak self] in
            self?.showImageDiscoverySheet = true
        })
        presentations.register(openable: .init(name: "Batch Jobs", screen: AppMode.portal.rawValue) { [weak self] in
            self?.headlessMonitor?.detailPresented = true
        })
        for sheet in [ActiveSheet.about, .export, .agentProposals, .features, .mcpSetupWizard] {
            presentations.register(openable: .init(name: sheet.title, screen: nil) { [weak self] in
                self?.activeSheet = sheet
            })
        }
    }
}
