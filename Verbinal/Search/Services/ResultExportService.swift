// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Orchestrates the non-SwiftUI I/O for the "Export results" feature: the
/// server-side VOTable/CSV/TSV download and the client-side CSV/TSV write.
///
/// Both paths produce a file on disk (a temp URL) which the caller then hands
/// to the platform save UI (`NSSavePanel` on macOS). Keeping the URLSession
/// timeout tuning, temp-file moves, and `ClientExporter` invocation here lets
/// `SearchResultsView` stay focused on SwiftUI composition and makes the I/O
/// independently testable with a stubbed `URLSession`/`URLProtocol`.
///
/// Distinct from ``SearchExporter`` (saved-query/recent-search JSON+Markdown,
/// excluded from the iOS target) — this exporter handles tabular *result*
/// export and is cross-platform.
enum ResultExportService {

    /// Per-request and per-resource timeouts for the server-side download. The
    /// default 60s is too tight for large VOTable exports of 10k+ rows; a
    /// stalled transfer should eventually fail rather than hang the UI's
    /// "Export…" indicator forever.
    enum Timeout {
        static let request: TimeInterval = 300
        static let resource: TimeInterval = 600
    }

    enum ExportError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case noRows

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return String(localized: "Invalid server response.")
            case .httpStatus(let code):
                return String(localized: "Export failed (HTTP \(code)).")
            case .noRows:
                return String(localized: "No rows to export.")
            }
        }
    }

    /// Build a `URLSession` configured with the export timeouts. Tests inject a
    /// stubbed session instead.
    static func makeExportSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Timeout.request
        config.timeoutIntervalForResource = Timeout.resource
        return URLSession(configuration: config)
    }

    /// Download the full server-side query result and stage it at a stable
    /// temp URL named `results.<ext>`, returning that URL.
    ///
    /// On a non-200 response (or an invalid one) the downloaded temp file is
    /// removed before throwing, so no stray temp files are left behind.
    /// The passed `session` is NOT invalidated here — the caller owns its
    /// lifetime (so an injected test session survives, and the production
    /// session from ``makeExportSession()`` can be invalidated by the caller).
    static func exportServerSide(
        url: URL,
        ext: String,
        session: URLSession
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = Timeout.request

        let (tempURL, response) = try await session.download(for: request)

        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ExportError.invalidResponse
        }
        guard http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ExportError.httpStatus(http.statusCode)
        }

        let filename = "results.\(ext)"
        let stableTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: stableTemp.path) {
                try FileManager.default.removeItem(at: stableTemp)
            }
            try FileManager.default.moveItem(at: tempURL, to: stableTemp)
        } catch {
            // Move failed — clean up the original download so we don't leak it.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return stableTemp
    }

    /// Write the supplied rows + visible columns to a temp URL named
    /// `results.<format.pathExtension>` and return that URL.
    ///
    /// Throws ``ExportError/noRows`` for an empty input (so the caller surfaces
    /// a clear message instead of writing a header-only file). On any write
    /// failure the temp file is removed before rethrowing.
    static func exportClientSide(
        rows: [SearchResult],
        columns: SearchResultColumns,
        format: ClientExporter.Format
    ) throws -> URL {
        guard !rows.isEmpty else {
            throw ExportError.noRows
        }

        let filename = "results.\(format.pathExtension)"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try ClientExporter.write(
                rows: rows,
                columns: columns,
                format: format,
                to: tempURL
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return tempURL
    }
}
