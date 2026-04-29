// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Who initiated the call. Drives the proposal-budget bucket and the
/// permission gate matrix.
public enum OperationOrigin: Hashable, Sendable {
    /// In-app human operating the GUI directly. No budget cap; calls
    /// don't go through MCP at all (we still classify them so audit and
    /// proposal flows are uniform).
    case user

    /// AI client connected via MCP (Claude Desktop, custom integration,
    /// etc.). Identified by its self-reported clientID for budget
    /// accounting and audit. External agents must not be able to call
    /// `.user`-only tools.
    case external(clientID: String)
}
