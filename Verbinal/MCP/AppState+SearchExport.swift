// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Search: `export_search_results` — the results as a file in Downloads,
/// in the person's storage, or both.
extension AppState {
    /// Export current in-app results (when `adql` is omitted) or a
    /// caller-supplied TAP query. Matches `get_search_results` for the
    /// omit-adql path so agents can dump what the user is looking at. With
    /// `uploadToVOSpace` the file goes to the person's storage too, and with
    /// `keepLocal` false only there (plan 36 2.11).
    func runSearchExport(_ request: ExportSearchResultsTool.Payload,
                         vospace: VOSpaceBrowserService) async throws -> SearchExport {
        var export = try await writeSearchExport(format: request.format, adql: request.adql, maxRecords: request.maxRecords)
        guard request.goesToStorage, let path = export.path else { return export }
        guard !username.isEmpty else {
            throw ProposalApplyError.backendError("Sign in to CADC before exporting to storage — the file is at \(path)")
        }
        let file = URL(fileURLWithPath: path)
        do {
            export.storagePath = try await ResultUpload(vospace: vospace, username: username).upload(file, to: request.vospacePath)
        } catch {
            throw ProposalApplyError.backendError("the file is at \(path), but storage did not take it: \(error.localizedDescription)")
        }
        if request.keepLocal == false {
            try? FileManager.default.removeItem(at: file)
            export.path = nil
        }
        return export
    }

    private func writeSearchExport(format: String, adql: String?, maxRecords: Int?) async throws -> SearchExport {
        let custom = adql?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty {
            return SearchExport(path: try await Self.exportServerADQL(format: format, adql: custom, maxRecords: maxRecords), shape: nil)
        }
        let snapshot: (rows: [SearchResult], columns: SearchResultColumns, liveADQL: String) = await MainActor.run {
            let model = self.searchModel.resultsModel
            return (model.fullFilteredSortedResults, model.columns, model.adqlQuery)
        }
        guard !snapshot.rows.isEmpty else {
            throw ProposalApplyError.backendError(
                "No current search results to export — run a search or pass `adql`."
            )
        }
        let capped = maxRecords.map { Array(snapshot.rows.prefix($0)) } ?? snapshot.rows
        let shown = SearchExport.shown(rows: capped.count, columns: snapshot.columns.visible.count)
        switch format {
        case "csv":
            let temp = try ResultExportService.exportClientSide(rows: capped, columns: snapshot.columns, format: .csv)
            return SearchExport(path: try Self.moveExportToDownloads(tempURL: temp, ext: "csv"), shape: shown)
        case "tsv":
            let temp = try ResultExportService.exportClientSide(rows: capped, columns: snapshot.columns, format: .tsv)
            return SearchExport(path: try Self.moveExportToDownloads(tempURL: temp, ext: "tsv"), shape: shown)
        case "votable":
            let live = snapshot.liveADQL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !live.isEmpty else {
                throw ProposalApplyError.backendError(
                    "VOTable export of the current table needs the live ADQL (none loaded). Pass `adql`, or export csv/tsv."
                )
            }
            return SearchExport(path: try await Self.exportServerADQL(format: format, adql: live, maxRecords: maxRecords ?? capped.count),
                                shape: nil)
        default:
            throw ProposalApplyError.backendError("unsupported format '\(format)'")
        }
    }

    private nonisolated static func exportServerADQL(
        format: String, adql: String, maxRecords: Int?
    ) async throws -> String {
        let ext: String
        switch format {
        case "csv": ext = "csv"
        case "tsv": ext = "tsv"
        case "votable": ext = "xml"
        default: throw ProposalApplyError.backendError("unsupported format '\(format)'")
        }
        var components = URLComponents(string: TAPConfig.syncURL)
        components?.queryItems = [
            URLQueryItem(name: "LANG", value: "ADQL"),
            URLQueryItem(name: "FORMAT", value: format),
            URLQueryItem(name: "QUERY", value: adql),
            URLQueryItem(name: "MAXREC", value: String(maxRecords ?? TAPConfig.maxRecords)),
        ]
        guard let url = components?.url else {
            throw ProposalApplyError.backendError("could not build the TAP export URL")
        }
        let temp = try await ResultExportService.exportServerSide(
            url: url, ext: ext, session: ResultExportService.makeExportSession())
        return try moveExportToDownloads(tempURL: temp, ext: ext)
    }

    private nonisolated static func moveExportToDownloads(tempURL: URL, ext: String) throws -> String {
        // Two exports in one second share a name: the first is kept.
        let name = DownloadsFolder.timestampedURL(stem: "verbinal-results", ext: ext).lastPathComponent
        return try DownloadsFolder.move(tempURL, named: name).path
    }
}
