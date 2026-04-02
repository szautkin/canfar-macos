// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SearchRootView: View {
    var searchModel: SearchFormModel
    var researchModel: ResearchModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            tabBar
            Divider()

            // Content + side panel
            HStack(alignment: .top, spacing: 0) {
                // Main content
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Right side panel
                sidePanel
                    .frame(width: 280)
            }
        }
        .task {
            await searchModel.dataTrainModel.loadData()
        }
    }

    private var resultsTabLabel: String {
        let count = searchModel.resultsModel.totalRows
        return count > 0 ? "Results (\(count))" : "Results"
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            Picker("", selection: Bindable(searchModel).selectedTab) {
                Text("Search").tag(SearchFormModel.SearchTab.search)
                Text(resultsTabLabel).tag(SearchFormModel.SearchTab.results)
                Text("ADQL").tag(SearchFormModel.SearchTab.adql)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)

            Spacer()

            if searchModel.isSearching {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch searchModel.selectedTab {
        case .search:
            SearchFormView(searchModel: searchModel)
        case .results:
            SearchResultsView(resultsModel: searchModel.resultsModel, tapClient: searchModel.tapClient, researchModel: researchModel)
        case .adql:
            ADQLEditorView(searchModel: searchModel)
        }
    }

    // MARK: - Side Panel

    private var sidePanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                RecentSearchesView(
                    store: searchModel.recentSearchStore,
                    onLoad: { snapshot in
                        searchModel.loadFromSnapshot(snapshot)
                    }
                )

                SavedQueriesView(
                    store: searchModel.savedQueryStore,
                    onRun: { adql in
                        Task { await searchModel.executeRawQuery(adql) }
                    },
                    onLoad: { adql in
                        searchModel.resultsModel.adqlQuery = adql
                        searchModel.selectedTab = .adql
                    },
                    currentQuery: searchModel.resultsModel.adqlQuery
                )
            }
            .padding(12)
        }
    }
}
