// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os

/// Receives one `AuditEntry` per dispatch. Implementations decide where
/// the data lands (os.log, Console.app, a file, an in-memory ring for
/// the Settings audit viewer).
public protocol AuditSink: Sendable {
    func record(_ entry: AuditEntry)
}

/// Emits each entry as a structured `os.Logger` `.notice` message.
///
/// View in Console.app or via:
///
/// ```
/// log show --predicate 'subsystem == "com.codebg.Verbinal.agent"'
/// ```
public struct LoggingAuditSink: AuditSink {
    private let logger: Logger

    public init(subsystem: String = "com.codebg.Verbinal.agent",
                category: String = "audit") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func record(_ entry: AuditEntry) {
        logger.notice("\(entry.line(), privacy: .public)")
    }
}

/// Test/debug sink that captures entries in memory.
public final class CapturingAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AuditEntry] = []

    public init() {}

    public func record(_ entry: AuditEntry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    public func snapshot() -> [AuditEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}
