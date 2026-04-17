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
                            .frame(maxWidth: .infinity)
                        SpatialConstraintsView(
                            formState: searchModel.formState,
                            resolverStatus: searchModel.resolverStatus,
                            onTargetChanged: { searchModel.targetChanged() }
                        )
                        .frame(maxWidth: .infinity)
                        TemporalConstraintsView(formState: searchModel.formState)
                            .frame(maxWidth: .infinity)
                        SpectralConstraintsView(formState: searchModel.formState)
                            .frame(maxWidth: .infinity)
                    }

                    // Data train
                    DataTrainView(
                        dataTrainModel: searchModel.dataTrainModel,
                        formState: searchModel.formState
                    )
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
                                .scaleEffect(0.7)
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

            Spacer()

            if let error = searchModel.searchError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
