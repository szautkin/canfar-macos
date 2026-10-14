// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

extension AgentsService {
    /// The server (plan 38): off, listening — with a warning when it is up
    /// but the helper's address could not be written — or why it is not.
    enum ServerState: Equatable, Sendable {
        case off
        case listening(warning: Problem?)
        case failed(Problem)
    }

    var isRunning: Bool { if case .listening = serverState { true } else { false } }

    /// What is wrong with the server, when something is.
    var serverProblem: Problem? {
        switch serverState {
        case .off: nil
        case .listening(let warning): warning
        case .failed(let problem): problem
        }
    }
}
