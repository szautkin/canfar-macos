// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

/// An assistant's session with Verbinal (plan 25): what starts it, what
/// works before it, how replies name it, and the words that tell the
/// assistant — one place for the app's bridge, the relay and
/// `describe_app`.
public enum AgentSession {
    /// The tools that work before a session: starting one, and learning how.
    public static let openBeforeSession: Set<String> = ["start_session", "describe_app"]
    /// Every reply names its session in `_meta`, under Verbinal's own key.
    public static let metaKey = "com.codebg.verbinal/session"
    /// What every assistant is told first, in both MCP versions' answers,
    /// `describe_app`'s brief and AGENTS.md.
    public static let instructions = "Call `start_session` first, saying who you are and your purpose. The person approves it in Verbinal and may give you instructions for the session: follow them. Its `session` id identifies every log entry of your session; `get_session_log` reads them. Without a session, no other tool works but `describe_app`."
}
