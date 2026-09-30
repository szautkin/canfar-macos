// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Writing session logs out, for the person to read or attach to a report,
/// or for tools (plan 23 L4): one or several sessions into one file, each
/// headed by its header. The one writer — the person's Export and an
/// assistant's `export_session_log` both come here, and it records the
/// export as a change.
enum SessionLogExport {
    enum Format: String, Codable, Sendable, CaseIterable {
        /// The lines, as the view shows them.
        case text
        /// The entries, as stored.
        case jsonl

        var fileExtension: String { self == .text ? "txt" : "jsonl" }
    }

    typealias Log = (header: SessionLogHeader, entries: [SessionLogEntry])

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// The logs as text: each session's header in words, then its lines,
    /// a call's requests under it, a failure's codes after it.
    static func text(_ logs: [Log]) -> String {
        logs.map { log in
            let header = log.header
            let endpoints = header.endpoints.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            var lines = [
                "Verbinal session log — \(header.client)",
                "Session \(header.session.uuidString), opened \(stamp.string(from: header.opened)); Verbinal \(header.app)\(header.buildCommit.map { ", \($0)" } ?? ""), macOS \(header.macOS)",
                "Endpoints: \(endpoints.isEmpty ? "—" : endpoints) (overridden: \(header.overridden.isEmpty ? "none" : header.overridden.joined(separator: ", "))). Auto-apply \(header.autoApply ? "on" : "off"). \(header.signedIn ? "Signed in" : "Not signed in").",
                "",
            ]
            for entry in log.entries {
                lines.append("[\(entry.token)] \(SessionLogLine.timed(entry))" + codes(entry))
                for request in entry.requests ?? [] {
                    let code = request.code.map { ", \($0)" } ?? ""
                    lines.append("      · \(request.name): \(request.meaning), \(CallTiming.duration(request.seconds)) of \(Int(request.timeout)) s\(code)")
                }
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private static func codes(_ entry: SessionLogEntry) -> String {
        guard let codes = entry.codes, entry.isFailure || entry.kind == .request else { return "" }
        let parts = [codes.status.map { "HTTP \($0)" }, codes.error.map { "URLError \($0)" }, codes.tag].compactMap { $0 }
        return parts.isEmpty ? "" : " [\(parts.joined(separator: ", "))]"
    }

    /// The logs as JSON Lines, each session's header before its entries —
    /// the stored form.
    static func jsonl(_ logs: [Log]) -> Data {
        logs.reduce(into: Data()) { data, log in
            data.append(SessionLogStore.line(SessionLogRecord(header: log.header)))
            for entry in log.entries { data.append(SessionLogStore.line(SessionLogRecord(entry: entry))) }
        }
    }

    /// "Verbinal session log 2026-09-30 1402" or "Verbinal session logs …".
    static func name(for count: Int, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Verbinal session \(count == 1 ? "log" : "logs") \(formatter.string(from: date))"
    }

    /// Writes `logs` to `url` as `format`, recorded as a change.
    static func write(_ logs: [Log], as format: Format, to url: URL, changes: ChangeLog = .shared) throws {
        let what = "\(logs.count) session \(logs.count == 1 ? "log" : "logs") to \(url.lastPathComponent)"
        do {
            let data = format == .text ? Data(text(logs).utf8) : jsonl(logs)
            try data.write(to: url, options: .atomic)
            changes.done("export_session_log", what)
        } catch {
            changes.failed("export_session_log", what, because: error.localizedDescription)
            throw error
        }
    }
}
