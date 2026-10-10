// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A working copy of a workflow as the sync carries it (plan 36 3.3): its
/// file's name and text — a step ticked on one Mac is ticked on the other.
/// Its date is the file's, not part of what it says.
struct WorkflowFile: Codable, Equatable, Sendable {
    var slug: String
    var text: String
    var modified: Date = .distantPast

    enum CodingKeys: String, CodingKey { case slug, text }
}
