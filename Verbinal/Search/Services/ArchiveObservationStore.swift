// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import GRDB
import os.log

/// The archive's answers kept on this Mac, by observation URI, so an
/// observation's record is asked of CADC once (plan 19 R1).
protocol ArchiveObservationStore: Sendable {
    /// The archive's answer as it came; nil when none is kept.
    func answer(for uri: String) -> Data?
    func keep(_ answer: Data, for uri: String)
}

/// In the app's SQLite database (`AppDatabase` v3, `archiveObservation`).
struct DatabaseArchiveObservationStore: ArchiveObservationStore {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "ArchiveObservations")
    let database: AppDatabase

    func answer(for uri: String) -> Data? {
        do {
            return try database.reader.read { db in
                try Data.fetchOne(db, sql: "SELECT xml FROM archiveObservation WHERE uri = ?", arguments: [uri])
            }
        } catch {
            Self.logger.error("Read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func keep(_ answer: Data, for uri: String) {
        do {
            try database.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO archiveObservation (uri, xml, fetchedAt) VALUES (?, ?, ?)
                    ON CONFLICT(uri) DO UPDATE SET xml = excluded.xml, fetchedAt = excluded.fetchedAt
                    """, arguments: [uri, answer, ISO8601DateFormatter().string(from: Date())])
            }
        } catch {
            Self.logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
