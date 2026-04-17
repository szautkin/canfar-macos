// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// Exports saved ADQL queries and recent searches as JSON + Markdown.
///
/// Lives in the Search feature module — depends on `ExportableModule` in the Export
/// module. Markdown output places ADQL in fenced `sql` code blocks so Claude and
/// other LLMs can parse/execute/rewrite the user's queries.
@MainActor
final class SearchExporter: ExportableModule {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "SearchExporter")
    let moduleID = "search"
    let displayName = "Search"

    private let savedQueryStore: SavedQueryStore
    private let recentSearchStore: RecentSearchStore

    init(savedQueryStore: SavedQueryStore, recentSearchStore: RecentSearchStore) {
        self.savedQueryStore = savedQueryStore
        self.recentSearchStore = recentSearchStore
    }

    func export(options: ExportOptions) async throws -> ExportModuleOutput {
        Self.logger.info("Export started: saved=\(self.savedQueryStore.queries.count) recent=\(self.recentSearchStore.searches.count) includeHistory=\(options.includeSearchHistory)")
        var output = ExportModuleOutput()

        let encoder = ExportEncoding.jsonEncoder()

        let saved = savedQueryStore.queries
        do {
            let savedData = try encoder.encode(saved)
            output.jsonFiles["saved_queries.json"] = savedData
            output.itemCounts["saved_queries"] = saved.count
        } catch {
            Self.logger.error("Saved query encode failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        if options.includeSearchHistory {
            let recent = recentSearchStore.searches
            do {
                let recentData = try encoder.encode(recent)
                output.jsonFiles["recent_searches.json"] = recentData
                output.itemCounts["recent_searches"] = recent.count
            } catch {
                Self.logger.error("Recent search encode failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        output.markdownFiles["queries.md"] = Self.renderQueriesMarkdown(
            saved: saved,
            recent: options.includeSearchHistory ? recentSearchStore.searches : []
        )

        return output
    }

    private static func renderQueriesMarkdown(
        saved: [SavedQuery],
        recent: [RecentSearch]
    ) -> String {
        var md = "# Search Queries\n\n"
        md += "Exported \(ExportEncoding.iso8601.string(from: Date()))\n\n"
        md += "- \(saved.count) saved quer\(saved.count == 1 ? "y" : "ies")\n"
        md += "- \(recent.count) recent search\(recent.count == 1 ? "" : "es")\n\n"
        md += "---\n\n"

        if !saved.isEmpty {
            md += "## Saved ADQL Queries\n\n"
            for query in saved {
                md += "### \(query.name)\n\n"
                md += "Saved \(ExportEncoding.iso8601.string(from: query.savedAt))\n\n"
                md += "```sql\n"
                md += query.adql
                if !query.adql.hasSuffix("\n") { md += "\n" }
                md += "```\n\n"
            }
            md += "---\n\n"
        }

        if !recent.isEmpty {
            md += "## Recent Searches\n\n"
            for search in recent {
                md += "### \(search.name)\n\n"
                md += "- **Saved:** \(ExportEncoding.iso8601.string(from: search.savedAt))\n"
                let snap = search.formSnapshot
                if !snap.target.isEmpty {
                    md += "- **Target:** \(snap.target)\n"
                }
                if !snap.selectedCollections.isEmpty {
                    md += "- **Collections:** \(snap.selectedCollections.joined(separator: ", "))\n"
                }
                if !snap.selectedInstruments.isEmpty {
                    md += "- **Instruments:** \(snap.selectedInstruments.joined(separator: ", "))\n"
                }
                if !snap.selectedBands.isEmpty {
                    md += "- **Bands:** \(snap.selectedBands.joined(separator: ", "))\n"
                }
                md += "\n"
            }
        }

        if saved.isEmpty && recent.isEmpty {
            md += "_No saved queries or recent searches yet._\n"
        }

        return md
    }
}
