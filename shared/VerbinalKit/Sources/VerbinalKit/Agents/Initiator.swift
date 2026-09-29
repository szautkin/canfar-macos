// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Who set a piece of work going: the person, their assistant, or the app
/// on its own. The activity bar and `list_activity` say it, so a trail
/// such as "Delete session …" can say whose it was (QA, plan 17 A1).
public enum Initiator: String, Codable, Sendable {
    case person
    case assistant
    case app

    /// Who is acting in the current task. The person unless a caller says
    /// otherwise: the tool router runs an assistant's call as the
    /// assistant, and applying an assistant's proposal is the assistant's
    /// work, whoever approved it. Work started in a `Task` inherits it.
    @TaskLocal public static var current: Initiator = .person
}
