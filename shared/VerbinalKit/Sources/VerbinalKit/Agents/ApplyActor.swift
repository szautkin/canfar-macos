// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Who applied a proposal. Without it a person's click, auto-apply and an
/// agent's background start looked the same afterwards, and a deletion
/// could be put down to the person only by its timing.
public enum ApplyActor: String, Codable, Sendable, Equatable, CaseIterable {
    /// The person, from Pending.
    case person
    /// Auto-apply, as the agent's call arrived.
    case autoApply
    /// An agent's `start_background_apply`, under auto-apply's rule.
    case background
}
