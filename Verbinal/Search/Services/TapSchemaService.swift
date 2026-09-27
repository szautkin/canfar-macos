// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// The archive's own `TAP_SCHEMA`, fetched on first use and kept for an
/// hour — the column set moves when CADC deploys a CAOM release, not while
/// someone works, and the whole schema (~400 columns) is a second's fetch.
/// Read live rather than baked in because the model moves ("new in 2.4").
///
/// One instance, owned by the search model, serves the ADQL editor (which
/// checks against ``cached`` as the person types, never waiting on the
/// network) and the agent tools.
@Observable
@MainActor
final class TapSchemaService {
    static let cacheTTL: TimeInterval = 60 * 60
    /// Guards against a runaway answer; the real one is ~400 rows.
    static let maxRows = 10_000

    /// Runs one ADQL query and returns its rows.
    typealias Query = @Sendable (_ adql: String, _ maxRows: Int) async throws -> TapSchema.Rows

    private let query: Query
    private let now: @Sendable () -> Date
    private var fetched: (at: Date, schema: TapSchema)?
    private var inFlight: Task<TapSchema, Error>?

    init(query: @escaping Query, now: @escaping @Sendable () -> Date = { Date() }) {
        self.query = query
        self.now = now
    }

    convenience init(tapClient: TAPClient) {
        self.init(query: { adql, maxRows in try await tapClient.tapQueryRows(adql: adql, maxRec: maxRows) })
    }

    /// The schema if it is known and fresh; never a fetch.
    var cached: TapSchema? {
        guard let fetched, now().timeIntervalSince(fetched.at) < Self.cacheTTL else { return nil }
        return fetched.schema
    }

    /// The schema, fetched when not cached. Concurrent callers share one fetch.
    func schema() async throws -> TapSchema {
        if let cached { return cached }
        if let inFlight { return try await inFlight.value }
        let query = query
        let task = Task { try await Self.fetch(with: query) }
        inFlight = task
        defer { inFlight = nil }
        let schema = try await task.value
        fetched = (now(), schema)
        return schema
    }

    /// Starts a fetch in the background when nothing is cached (the editor
    /// calls this when it appears, so checking can begin soon after).
    func prefetch() {
        guard cached == nil, inFlight == nil else { return }
        Task { _ = try? await schema() }
    }

    private nonisolated static func fetch(with query: Query) async throws -> TapSchema {
        // Three queries rather than one join, so a service without `keys`
        // still yields its tables and columns.
        do {
            let tables = try await query("SELECT table_name, description FROM TAP_SCHEMA.tables ORDER BY table_name", maxRows)
            let columns = try await query(
                "SELECT table_name, column_name, datatype, description, unit, ucd FROM TAP_SCHEMA.columns ORDER BY table_name, column_name",
                maxRows)
            let keys = (try? await query(
                "SELECT k.from_table, k.target_table, kc.from_column, kc.target_column, k.description FROM TAP_SCHEMA.keys AS k JOIN TAP_SCHEMA.key_columns AS kc ON k.key_id = kc.key_id",
                maxRows)) ?? (headers: [], rows: [])
            return TapSchema.build(tables: tables, columns: columns, keys: keys)
        } catch {
            throw SearchError.networkError("TAP_SCHEMA query failed: \(error.localizedDescription)")
        }
    }
}
