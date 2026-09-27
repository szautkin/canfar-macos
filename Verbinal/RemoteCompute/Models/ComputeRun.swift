// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One piece of code sent to the remote compute session, as the app
/// remembers it.
///
/// The request and result files on /arc say nothing about who asked —
/// their format is shared with the watcher and with Verbinal for Windows —
/// so who asked is kept here. The output is not copied (it can run to a
/// megabyte); it is read from the result file when someone opens the run.
struct ComputeRun: Codable, Equatable, Identifiable, Sendable {
    /// An assistant through `run_code`, or the person at the Remote Compute screen.
    enum Author: String, Codable, Sendable {
        case agent
        case user
    }

    /// Still out: sent, nothing back yet.
    static let running = "running"
    /// Set by the app: nothing came back in the time the run could have taken.
    static let noResult = "noResult"
    /// Set by the app: the request never reached the session.
    static let notSent = "notSent"

    let id: String
    let author: Author
    let language: String
    let code: String
    let timeoutSeconds: Int
    let submittedAt: Date
    /// The watcher's verdict — `ok`, `error` or `timeout` — or the app's own
    /// `noResult` / `notSent`; nil while the run is out.
    var status: String?
    var exitCode: Int?
    var durationMs: Int?
    var finishedAt: Date?

    init(_ request: RunCodeContract.Request, author: Author, submittedAt: Date = Date()) {
        id = request.id
        self.author = author
        language = request.language
        code = request.code
        timeoutSeconds = request.timeout_seconds
        self.submittedAt = submittedAt
    }

    /// Whether anything more is going to happen to it.
    var isFinished: Bool { status != nil }

    /// Where it stands, including while it is out.
    var state: String { status ?? Self.running }
}
