// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Pointing at the interface: what can be pointed at, and the hint.
extension AppState {
    func makeListUITargetsTool() -> ListUITargetsTool {
        let registry = uiPointer
        return ListUITargetsTool(targets: { await MainActor.run { Array(registry.targets.values) } })
    }

    func makePointAtUITool() -> PointAtUITool {
        let registry = uiPointer
        let activity = agentsService.activityStore
        return PointAtUITool(point: { args in
            await MainActor.run {
                let outcome = registry.point(at: args.target, message: args.message, seconds: args.seconds)
                if case .pointed(let target) = outcome {
                    activity.append(.live(kind: "point_at_ui", summary: "Pointed at \(target.label)",
                                          origin: .external(clientID: "point_at_ui")))
                }
                return outcome
            }
        })
    }

    func makeOpenSettingsTool() -> LiveActionTool<SettingsActions.OpenArgs> {
        SettingsActions.open { [weak self] args in
            guard let self else { return "App state unavailable" }
            let section: SettingsSection?
            if let raw = args.section {
                guard let known = SettingsSection(rawValue: raw) else { return "no Settings section \"\(raw)\"" }
                section = known
            } else {
                section = nil
            }
            await MainActor.run {
                self.requestSettings(.open, section: section)
                self.agentsService.activityStore.append(.live(
                    kind: "open_settings", summary: "Opened Settings", origin: .external(clientID: "open_settings")))
            }
            return nil
        }
    }

    func makeCloseSettingsTool() -> LiveActionTool<SettingsActions.NoArgs> {
        SettingsActions.close { [weak self] _ in
            guard let self else { return "App state unavailable" }
            await MainActor.run { self.requestSettings(.close) }
            return nil
        }
    }
}
