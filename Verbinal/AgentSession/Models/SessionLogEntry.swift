// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// One entry of an assistant's session log (plan 23 L2): what happened, in
/// one sentence, with who, why, how it ended and how long, and the ids and
/// codes that link it to what caused it and help debugging. One frame for
/// every kind; a kind fills the fields it has. Meaning only — no
/// arguments, paths, queries, headers or bodies.
struct SessionLogEntry: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case opened, closed
        /// A change: created, launched, downloaded, deleted, …
        case action
        /// One of this session's tool calls.
        case call
        /// Work that is not a change: an image probe, the Research check.
        case task
        /// A proposal rejected, withdrawn or expired.
        case proposal
        /// A rule the app applied.
        case decision
        /// A request outside this session's calls that failed.
        case request
        /// Sign-in, services failing and recovering, assistants coming and going.
        case app
    }

    /// Who, as the session's reader sees it.
    enum Who: String, Codable, Sendable {
        /// This session's assistant.
        case assistant
        case anotherAssistant
        case person
        case app
    }

    /// What it is linked to.
    struct Links: Codable, Sendable, Equatable {
        var session: UUID?
        var call: UUID?
        var proposal: UUID?
        var task: Int?
        var request: Int?
    }

    /// For debugging a failure.
    struct Codes: Codable, Sendable, Equatable {
        /// HTTP status.
        var status: Int?
        /// `URLError` code.
        var error: Int?
        /// A tool failure's tag, or a decision's rule.
        var tag: String?
    }

    /// Its place in the session; the assistant reads what is new with `since`.
    /// The journal gives it.
    var token: Int
    let at: Date
    let kind: Kind
    /// The sentence the person's view shows and the text export writes.
    let line: String
    var who: Who?
    /// Another assistant's `name/version`.
    var client: String?
    var why: String?
    /// done, failed, cancelled, answered, proposed, waiting, …
    var outcome: String?
    var seconds: Double?
    /// A call's tool.
    var tool: String?
    /// Whether asking again can help: now, later, afterSignIn, no.
    var retry: String?
    var ids = Links()
    var codes: Codes?
    /// A call's requests.
    var requests: [CallTiming.Request]?

    var id: Int { token }
    var isFailure: Bool { outcome == "failed" }
}

/// A session's first line: who connected to what, and the app's state then
/// — what debugging a log starts from.
struct SessionLogHeader: Codable, Sendable, Equatable {
    /// Bumped when an entry changes shape; a reader skips what it does not know.
    static let currentSchema = 1

    var schema = SessionLogHeader.currentSchema
    let session: UUID
    /// The assistant's `name/version`.
    let client: String
    let opened: Date
    /// "1.4.0 (17)".
    let app: String
    let buildCommit: String?
    let macOS: String
    /// Each endpoint in use, by field.
    let endpoints: [String: String]
    /// The fields the person overrode.
    let overridden: [String]
    let autoApply: Bool
    let signedIn: Bool
}

/// A line of a session's file: its header, or an entry.
struct SessionLogRecord: Codable, Sendable {
    var header: SessionLogHeader?
    var entry: SessionLogEntry?
}
