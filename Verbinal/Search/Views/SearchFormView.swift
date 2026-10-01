// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SearchFormView: View {
    var searchModel: SearchFormModel

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable form content
            ScrollView {
                VStack(spacing: 16) {
                    // 4-column constraint row — top aligned
                    HStack(alignment: .top, spacing: 12) {
                        ObservationConstraintsView(formState: searchModel.formState)
                            .pointableArea("search.observation", label: String(localized: "Observation constraints"))
                            .frame(maxWidth: .infinity)
                        SpatialConstraintsView(
                            formState: searchModel.formState,
                            resolverStatus: searchModel.resolverStatus,
                            onTargetChanged: { searchModel.targetChanged() }
                        )
                        .pointableArea("search.spatial", label: String(localized: "Spatial constraints"))
                        .frame(maxWidth: .infinity)
                        TemporalConstraintsView(formState: searchModel.formState)
                            .pointableArea("search.temporal", label: String(localized: "Temporal constraints"))
                            .frame(maxWidth: .infinity)
                        SpectralConstraintsView(formState: searchModel.formState)
                            .pointableArea("search.spectral", label: String(localized: "Spectral constraints"))
                            .frame(maxWidth: .infinity)
                    }

                    // Data train
                    DataTrainView(
                        dataTrainModel: searchModel.dataTrainModel,
                        formState: searchModel.formState
                    )
                    .pointableArea("search.dataTrain", label: String(localized: "Collection, instrument and filter lists"))
                }
                .padding(16)
            }

            // Pinned action bar — never scrolls
            Divider()
            actionBar
        }
    }

    /// Fixed action bar at the bottom of the form — always visible.
    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await searchModel.executeSearch() }
            } label: {
                HStack(spacing: 6) {
                    ZStack {
                        Image(systemName: "magnifyingglass")
                            .opacity(searchModel.isSearching ? 0 : 1)
                        if searchModel.isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text("Search")
                }
                .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(searchModel.isSearching)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Execute search (⌘↩)")
            .pointable("search.run")

            SearchCancelButton(searchModel: searchModel)

            Button {
                searchModel.resetForm()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(searchModel.isSearching)
            .help("Clear all filters")
            .pointable("search.reset")

            Spacer()

            if let error = searchModel.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
