// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os.log
import GRDB

/// Owns the AI Guide state: per-tool description overrides and user-authored
/// instruction tools. GRDB-backed (v2 schema), mirrored in memory for synchronous
/// reads — same `@Observable @MainActor` store shape as ``ObservationNoteStore``.
///
/// Design notes:
///  * A built-in tool's description is the single source of truth and is NEVER
///    stored. An override is a sparse delta; "reset" soft-deletes the row.
///  * Guide tools are read-only: the agent CALLS one and a generic handler in the
///    MCP bridge returns the stored text (no execution). Name uniqueness among
///    LIVE guides is enforced here, not by a DB constraint, so a deleted name can
///    be reused.
///  * ``snapshot()`` produces a `Sendable` value the MCP bridge captures to
///    re-tune `tools/list` live (the bridge hops here per request).
@Observable
@MainActor
final class AIGuideService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "AIGuideService")

    private let db: AppDatabase
    private let deviceID: String

    /// LIVE description overrides, keyed by built-in tool name.
    private(set) var overrides: [String: String] = [:]

    /// LIVE user guide tools, ordered for display.
    private(set) var guides: [AIGuideToolEntry] = []

    /// Names of the registered built-in tools, set once by `AppState` after the
    /// agent tools are composed. Used to reject a guide name that would shadow a
    /// real tool. Empty until set (e.g. on iOS, where no agent runs).
    var knownToolNames: Set<String> = []

    // Validation caps — generous enough for a re-tuning paragraph, bounded so a
    // pathological value can't bloat the wire manifest or a tool-call response.
    static let maxDescriptionChars = 600
    static let maxBodyChars = 4000

    init(database: AppDatabase = .shared) {
        self.db = database
        self.deviceID = Self.installDeviceID()
        reload()
    }

    // MARK: - Read / merge

    /// Reload both in-memory mirrors from the DB (live rows only).
    func reload() {
        do {
            let ovRows = try db.reader.read { d in
                try Row.fetchAll(d, sql: "SELECT toolName, userDescription FROM aiToolOverride WHERE deletedAt IS NULL")
            }
            overrides = Dictionary(uniqueKeysWithValues: ovRows.compactMap { row -> (String, String)? in
                guard let name: String = row["toolName"], let desc: String = row["userDescription"] else { return nil }
                return (name, desc)
            })

            let gRows = try db.reader.read { d in
                try Row.fetchAll(d, sql: """
                    SELECT uuid, name, description, body FROM aiGuideTool
                    WHERE deletedAt IS NULL ORDER BY orderIndex ASC, name ASC
                    """)
            }
            guides = gRows.compactMap { Self.guide(from: $0) }
        } catch {
            Self.logger.error("reload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func effectiveDescription(toolName: String, default def: String) -> String {
        overrides[toolName] ?? def
    }

    func isOverridden(_ toolName: String) -> Bool { overrides[toolName] != nil }

    /// Merge the live built-in manifest with stored overrides into UI rows.
    func rows(forTools tools: [AIGuideToolInput]) -> [AIGuideTool] {
        tools.map { t in
            let override = overrides[t.name]
            return AIGuideTool(
                name: t.name,
                defaultDescription: t.defaultDescription,
                effectiveDescription: override ?? t.defaultDescription,
                isOverridden: override != nil,
                category: t.category
            )
        }
    }

    /// `Sendable` snapshot for the MCP bridge.
    func snapshot() -> AIGuideSnapshot {
        AIGuideSnapshot(overrides: overrides, guides: guides)
    }

    // MARK: - Tool description overrides

    /// Set (or, with empty text, clear) the override for a built-in tool.
    /// Trims whitespace; enforces the description cap.
    func setOverride(toolName: String, description: String) throws {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maxDescriptionChars else {
            throw AIGuideError.tooLong(field: "Description", limit: Self.maxDescriptionChars)
        }
        if trimmed.isEmpty { clearOverride(toolName: toolName); return }

        let now = Self.iso(Date())
        do {
            try db.writer.write { [deviceID] d in
                try d.execute(sql: """
                    INSERT INTO aiToolOverride
                        (uuid, toolName, userDescription, createdAt, updatedAt, version, deletedAt, lastWriterDeviceID)
                    VALUES (?, ?, ?, ?, ?, 1, NULL, ?)
                    ON CONFLICT(toolName) DO UPDATE SET
                        userDescription = excluded.userDescription,
                        updatedAt = excluded.updatedAt,
                        version = aiToolOverride.version + 1,
                        deletedAt = NULL,
                        lastWriterDeviceID = excluded.lastWriterDeviceID
                    """, arguments: [UUID().uuidString, toolName, trimmed, now, now, deviceID])
            }
            overrides[toolName] = trimmed
        } catch {
            Self.logger.error("setOverride failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reset a tool to its built-in description (soft-delete the override row).
    func clearOverride(toolName: String) {
        guard overrides[toolName] != nil else { return }
        let now = Self.iso(Date())
        do {
            try db.writer.write { [deviceID] d in
                try d.execute(sql: """
                    UPDATE aiToolOverride
                    SET deletedAt = ?, updatedAt = ?, version = version + 1, lastWriterDeviceID = ?
                    WHERE toolName = ? AND deletedAt IS NULL
                    """, arguments: [now, now, deviceID, toolName])
            }
            overrides[toolName] = nil
        } catch {
            Self.logger.error("clearOverride failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Custom guide tools

    /// Create a new guide tool. Returns the stored entry (with its assigned slug
    /// + id). Throws ``AIGuideError`` on validation failure.
    @discardableResult
    func addGuide(name: String, description: String, body: String?) throws -> AIGuideToolEntry {
        let slug = try validatedName(name, excluding: nil)
        let desc = try validatedDescription(description)
        let bod = try validatedBody(body)

        let entry = AIGuideToolEntry(id: UUID(), name: slug, description: desc, body: bod)
        let order = guides.count
        let now = Self.iso(Date())
        do {
            try db.writer.write { [deviceID] d in
                try d.execute(sql: """
                    INSERT INTO aiGuideTool
                        (uuid, name, description, body, orderIndex, createdAt, updatedAt, version, deletedAt, lastWriterDeviceID)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1, NULL, ?)
                    """, arguments: [entry.id.uuidString, slug, desc, bod, order, now, now, deviceID])
            }
            reload()
        } catch {
            Self.logger.error("addGuide failed: \(error.localizedDescription, privacy: .public)")
        }
        return entry
    }

    /// Update an existing guide. Re-validates the (possibly changed) name.
    func updateGuide(id: UUID, name: String, description: String, body: String?) throws {
        let slug = try validatedName(name, excluding: id)
        let desc = try validatedDescription(description)
        let bod = try validatedBody(body)
        let now = Self.iso(Date())
        do {
            try db.writer.write { [deviceID] d in
                try d.execute(sql: """
                    UPDATE aiGuideTool
                    SET name = ?, description = ?, body = ?, updatedAt = ?, version = version + 1, lastWriterDeviceID = ?
                    WHERE uuid = ? AND deletedAt IS NULL
                    """, arguments: [slug, desc, bod, now, deviceID, id.uuidString])
            }
            reload()
        } catch {
            Self.logger.error("updateGuide failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Soft-delete a guide tool.
    func deleteGuide(id: UUID) {
        let now = Self.iso(Date())
        do {
            try db.writer.write { [deviceID] d in
                try d.execute(sql: """
                    UPDATE aiGuideTool
                    SET deletedAt = ?, updatedAt = ?, version = version + 1, lastWriterDeviceID = ?
                    WHERE uuid = ? AND deletedAt IS NULL
                    """, arguments: [now, now, deviceID, id.uuidString])
            }
            reload()
        } catch {
            Self.logger.error("deleteGuide failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Validation

    private func validatedName(_ raw: String, excluding id: UUID?) throws -> String {
        let slug = Self.slug(raw)
        guard !slug.isEmpty else { throw AIGuideError.nameEmpty }
        guard !knownToolNames.contains(slug) else { throw AIGuideError.nameCollidesWithTool }
        let clash = guides.contains { $0.name == slug && $0.id != id }
        guard !clash else { throw AIGuideError.nameTaken }
        return slug
    }

    private func validatedDescription(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maxDescriptionChars else {
            throw AIGuideError.tooLong(field: "Description", limit: Self.maxDescriptionChars)
        }
        return trimmed
    }

    private func validatedBody(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= Self.maxBodyChars else {
            throw AIGuideError.tooLong(field: "Instructions", limit: Self.maxBodyChars)
        }
        return trimmed
    }

    /// Turn a display name into a valid MCP tool name: lowercase ASCII
    /// alphanumerics, with spaces/dashes/dots/underscores collapsed to a single
    /// `_`, trimmed of leading/trailing underscores. Non-ASCII letters are
    /// dropped (the agent-facing name must be wire-safe).
    static func slug(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch == " " || ch == "-" || ch == "_" || ch == "." {
                out.append("_")
            }
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    // MARK: - Row -> model

    private static func guide(from row: Row) -> AIGuideToolEntry? {
        guard let uuidStr: String = row["uuid"], let uuid = UUID(uuidString: uuidStr),
              let name: String = row["name"], let description: String = row["description"]
        else { return nil }
        let body: String? = row["body"]
        return AIGuideToolEntry(id: uuid, name: name, description: description, body: body)
    }

    // MARK: - Helpers

    private static let isoFormatter = ISO8601DateFormatter()

    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// Stable per-install device id (shared with the other stores via the same
    /// UserDefaults key) for the sync-readiness `lastWriterDeviceID` column.
    private static func installDeviceID() -> String {
        let key = "verbinal.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
