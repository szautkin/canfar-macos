// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CryptoKit
import Foundation

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
    public static let instructions = "Call `start_session` first, saying who you are and your purpose. The person approves it in Verbinal and may give you instructions for the session: follow them. Its `session` id identifies every log entry of your session; `get_session_log` reads them. Without a session, no other tool works but `describe_app`. Call it once: when Verbinal restarts, your session continues while your client keeps the same `Verbinal mcp` process; a new one starts a new session."

    // MARK: - The relay's secret (plan 34 S)

    /// The relay (`Verbinal mcp`) introduces itself to the app first on each
    /// connection, with a secret it makes once: a reconnection after
    /// Verbinal restarts continues the same session. The secret is never in
    /// a log or a reply — the session id is public, so it cannot be the key.
    public static let relayNotification = "notifications/com.codebg.verbinal/relay"

    /// A new relay's secret: 32 random bytes, base64url.
    public static func newRelaySecret() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The introduction the relay sends first on each connection.
    public static func relayIntroduction(secret: String) -> Data {
        let frame: [String: Any] = ["jsonrpc": "2.0", "method": relayNotification, "params": ["secret": secret]]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }

    /// What the app keeps of an introduction's secret: its SHA-256, in hex.
    /// Nil when the introduction carries no secret of the relay's shape.
    public static func relayFingerprint(introduction params: [String: Any]?) -> String? {
        guard let secret = params?["secret"] as? String, secret.count == 43,
              secret.unicodeScalars.allSatisfy({ CharacterSet.base64URL.contains($0) }) else { return nil }
        return SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension CharacterSet {
    static let base64URL = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}
