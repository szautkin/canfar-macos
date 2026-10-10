// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Search: ADQL — the schema, the checker, the editor — and running saved and recent searches.
extension AppState {
    // MARK: - Search form loading

    func makeLoadSavedSearchTool(
        savedStore: SavedQueryStore, recentStore: RecentSearchStore
    ) -> LoadSavedSearchTool {
        let activity = agentsService.activityStore
        return LoadSavedSearchTool(apply: { [weak self] savedID, recentID in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                if let savedID {
                    guard let uuid = UUID(uuidString: savedID),
                          let query = savedStore.queries.first(where: { $0.id == uuid }) else {
                        return "Saved query not found: \(savedID)"
                    }
                    self.pendingSearchLoad = AppState.PendingSearchLoad(kind: .adql(query.adql))
                    self.navigateTo(.search)
                    activity.append(.live(
                        kind: "load_saved_search",
                        summary: "Loaded saved query '\(query.name)' into the ADQL editor",
                        origin: .external(clientID: "load_saved_search")))
                    return nil
                }
                if let recentID {
                    guard let uuid = UUID(uuidString: recentID),
                          let recent = recentStore.searches.first(where: { $0.id == uuid }) else {
                        return "Recent search not found: \(recentID)"
                    }
                    self.pendingSearchLoad = AppState.PendingSearchLoad(
                    kind: recent.adql.map { .adql($0) } ?? .snapshot(recent.formSnapshot))
                    self.navigateTo(.search)
                    activity.append(.live(
                        kind: "load_saved_search",
                        summary: "Loaded recent search '\(recent.name)' into the \(recent.isFromEditor ? "ADQL editor" : "form")",
                        origin: .external(clientID: "load_saved_search")))
                    return nil
                }
                return "Pass savedQueryID or recentSearchID"
            }
        })
    }

    func makeLoadRecentSearchTool(recentStore: RecentSearchStore) -> LoadRecentSearchTool {
        let activity = agentsService.activityStore
        return LoadRecentSearchTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let recent: RecentSearch?
                if let id = args.recentSearchID {
                    recent = UUID(uuidString: id).flatMap { uuid in
                        recentStore.searches.first(where: { $0.id == uuid })
                    }
                    if recent == nil { return "Recent search not found: \(id)" }
                } else if let index = args.index {
                    guard recentStore.searches.indices.contains(index) else {
                        return "Recent search index \(index) out of range (count=\(recentStore.searches.count))"
                    }
                    recent = recentStore.searches[index]
                } else {
                    return "Pass index or recentSearchID"
                }
                guard let recent else { return "Recent search not found" }
                self.pendingSearchLoad = AppState.PendingSearchLoad(
                    kind: recent.adql.map { .adql($0) } ?? .snapshot(recent.formSnapshot))
                self.navigateTo(.search)
                activity.append(.live(
                    kind: "load_recent_search",
                    summary: "Loaded recent search '\(recent.name)' into the \(recent.isFromEditor ? "ADQL editor" : "form")",
                    origin: .external(clientID: "load_recent_search")))
                return nil
            }
        })
    }

    func makeRunSavedQueryTool(savedStore: SavedQueryStore) -> RunSavedQueryTool {
        let activity = agentsService.activityStore
        return RunSavedQueryTool(apply: { [weak self] args in
            guard let self else { return "App state unavailable" }
            return await MainActor.run {
                let query: SavedQuery?
                if let id = args.savedQueryID {
                    query = UUID(uuidString: id).flatMap { uuid in
                        savedStore.queries.first(where: { $0.id == uuid })
                    }
                    if query == nil { return "Saved query not found: \(id)" }
                } else if let name = args.name {
                    query = savedStore.queries.first(where: { $0.name == name })
                    if query == nil { return "Saved query not found: \(name)" }
                } else {
                    return "Pass name or savedQueryID"
                }
                guard let query else { return "Saved query not found" }
                self.navigateTo(.search)
                self.searchModel.selectedTab = .adql
                self.searchModel.resultsModel.adqlQuery = query.adql
                activity.append(.live(
                    kind: "run_saved_query",
                    summary: "Ran saved query '\(query.name)'",
                    origin: .external(clientID: "run_saved_query")))
                Task { await self.searchModel.executeRawQuery(query.adql) }
                return nil
            }
        })
    }

    /// The search model's schema service, fetched on first use.
    func tapSchemaSource() -> @Sendable () async throws -> TapSchema {
        let service = searchModel.tapSchema
        return { try await service.schema() }
    }

    func makeDescribeTapSchemaTool() -> DescribeTapSchemaTool {
        DescribeTapSchemaTool(schema: tapSchemaSource())
    }

    func makeValidateADQLQueryTool() -> ValidateADQLQueryTool {
        ValidateADQLQueryTool(schema: tapSchemaSource())
    }

    func makeSetADQLEditorTool() -> SetADQLEditorTool {
        let activity = agentsService.activityStore
        return SetADQLEditorTool(apply: { [weak self] args in
            guard let self else { return .init(error: "App state unavailable") }
            let model = self.searchModel
            let adql: String = await MainActor.run {
                if let text = args.adql {
                    model.resultsModel.adqlQuery = text
                } else if args.generateFromForm == true {
                    model.resultsModel.adqlQuery = ADQLBuilder.buildQuery(
                        formState: model.formState,
                        resolverCoords: Self.resolverCoords(of: model))
                }
                model.selectedTab = .adql
                return model.resultsModel.adqlQuery
            }
            var outcome = SetADQLEditorTool.Outcome(adql: adql)
            if args.execute == true {
                guard !adql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .init(error: "The ADQL editor is empty — pass `adql` or `generateFromForm`")
                }
                await MainActor.run {
                    model.nextSearchAttribution = .forLiveTool(
                        label: "set_adql_editor", summary: "Ran a query from the ADQL editor")
                }
                if args.wait == false {
                    Task { @MainActor in _ = await model.executeRawQuery(adql, fromEditor: true) }
                    outcome.started = true
                } else {
                    (outcome.executed, outcome.resultCount, outcome.searchError, outcome.cancelled) =
                        Self.report(await model.executeRawQuery(adql, fromEditor: true))
                }
            }
            await MainActor.run {
                activity.append(.live(
                    kind: "set_adql_editor",
                    summary: args.execute == true
                        ? "Set the ADQL editor and ran the query"
                        : "Set the ADQL editor",
                    origin: .external(clientID: "set_adql_editor")))
            }
            return outcome
        })
    }
}
