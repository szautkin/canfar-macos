// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A tab of the Settings window, by a stable id an agent can name.
enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, portal, agent, imageDiscovery, aiCompute, mcpClients, endpoints, about

    var id: String { rawValue }
}

/// A request from outside the Settings window — `open_settings` /
/// `close_settings` — carried in app state so the windows can act on it.
struct SettingsRequest: Equatable, Sendable {
    enum Action: Sendable { case open, close }
    let action: Action
    let serial: Int
}
