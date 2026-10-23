// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A run on the person's compute session, as the Compute screen lists it
/// (plan 47 2.2): what /arc keeps of it, and whether this device sent it.
struct ComputeRunItem: Identifiable, Equatable, Sendable {
    /// The id, as its files are named (`RunCodeContract.sanitize`).
    let id: String
    var language: String?
    var code: String?
    var timeoutSeconds: Int?
    /// The watcher's `ok`, `error` or `timeout`; or this device's own
    /// `running`, `noResult`, `notSent`.
    var status: String?
    var exitCode: Int?
    var durationMs: Int?
    var stdout: String?
    var stderr: String?
    var truncated = false
    /// When it finished, else when it was sent or last touched.
    var date: Date?
    /// Sent but not yet run: its request still waits in the inbox.
    var isWaiting = false
    /// Sent from this device (the files on /arc do not say who sent a run).
    var fromThisDevice = false

    var isFinished: Bool { status != nil && status != ComputeRun.running && !isWaiting }
    var isFailure: Bool { ["error", "timeout", ComputeRun.noResult, ComputeRun.notSent].contains(status ?? "") }
    /// The code's first non-empty line, for the list.
    var firstLine: String {
        code?.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
    }
}

/// Every run /arc keeps, read back for the Compute screen. The watcher
/// writes each result to `.verbinal/exec/out/<id>.json`, then moves the
/// request — the code — to `done/<id>.json`; a request not yet run is still
/// in `inbox/<id>.json`. Runs from any device, and an assistant's, are there.
enum ComputeRunItems {
    /// A file in one of the three folders, as a listing gives it.
    struct ArcFile: Equatable, Sendable {
        let name: String
        let modified: Date?
    }

    /// One run's files.
    struct Listing: Equatable, Sendable {
        let id: String
        let hasResult: Bool
        let hasRequest: Bool
        /// Its request waits in the inbox, with no result yet.
        let isWaiting: Bool
        let modified: Date?
    }

    /// The newest `limit` runs, by their files' dates. Only whole `<id>.json`
    /// files count: a `.partial` is a result still being written.
    static func listings(out: [ArcFile], done: [ArcFile], inbox: [ArcFile], limit: Int) -> [Listing] {
        func stems(_ files: [ArcFile]) -> [String: Date?] {
            var byID: [String: Date?] = [:]
            for file in files where file.name.hasSuffix(".json") {
                byID[String(file.name.dropLast(".json".count)).lowercased()] = file.modified
            }
            return byID
        }
        let results = stems(out), requests = stems(done), waiting = stems(inbox)
        let ids = Set(results.keys).union(requests.keys).union(waiting.keys)
        let listings = ids.map { id in
            Listing(id: id,
                    hasResult: results[id] != nil,
                    hasRequest: requests[id] != nil,
                    isWaiting: waiting[id] != nil && results[id] == nil,
                    modified: (results[id] ?? nil) ?? (waiting[id] ?? nil) ?? (requests[id] ?? nil))
        }
        return Array(listings.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(limit))
    }

    /// A run from its files.
    static func item(_ listing: Listing, request: RunCodeContract.Request?,
                     result: RunCodeContract.ResultFile?) -> ComputeRunItem {
        var item = ComputeRunItem(id: listing.id)
        item.language = request?.language
        item.code = request?.code
        item.timeoutSeconds = request?.timeout_seconds
        item.isWaiting = listing.isWaiting
        item.date = listing.modified
        if let result {
            item.status = result.status?.trimmingCharacters(in: .whitespaces).lowercased()
            item.exitCode = result.exit_code
            item.durationMs = result.duration_ms
            item.stdout = result.decodedStdout
            item.stderr = result.decodedStderr
            item.truncated = result.truncated == true
            item.date = result.finished_at.flatMap(parseDate) ?? listing.modified
        }
        return item
    }

    /// /arc's runs with this device's: those sent from here are marked, and
    /// those not on /arc yet (still out, or never sent) are added from here.
    /// Newest first.
    static func merge(arc: [ComputeRunItem], local: [ComputeRun]) -> [ComputeRunItem] {
        let localByID = Dictionary(local.map { (RunCodeContract.sanitize($0.id).lowercased(), $0) },
                                   uniquingKeysWith: { first, _ in first })
        var items = arc.map { item -> ComputeRunItem in
            guard let run = localByID[item.id] else { return item }
            var marked = item
            marked.fromThisDevice = true
            marked.code = marked.code ?? run.code
            marked.language = marked.language ?? run.language
            marked.timeoutSeconds = marked.timeoutSeconds ?? run.timeoutSeconds
            return marked
        }
        let onArc = Set(arc.map(\.id))
        for (id, run) in localByID where !onArc.contains(id) {
            var item = ComputeRunItem(id: id)
            item.language = run.language
            item.code = run.code
            item.timeoutSeconds = run.timeoutSeconds
            item.status = run.state
            item.exitCode = run.exitCode
            item.durationMs = run.durationMs
            item.date = run.finishedAt ?? run.submittedAt
            item.fromThisDevice = true
            items.append(item)
        }
        return items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// The FITS files a run's output names in the person's home, relative to
    /// it, once each, in order: `/arc/home/<user>/out/m31.fits` and
    /// `~/out/m31.fits` are `out/m31.fits` (plan 47 2.6: review what it made).
    static func homeFITSPaths(in text: String, username: String) -> [String] {
        guard !username.isEmpty else { return [] }
        let home = NSRegularExpression.escapedPattern(for: "/arc/home/\(username)/")
        let pattern = "(?:\(home)|~/)([^\\s'\"`]+?\\.(?:fits|fit|fts)(?:\\.fz)?)(?![\\w.])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var seen: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let path = String(text[range])
            if !path.contains(".."), !seen.contains(path) { seen.append(path) }
        }
        return seen
    }

    private static func parseDate(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
