// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SearchFormView: View {
    var searchModel: SearchFormModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Action bar
                HStack {
                    Button {
                        Task { await searchModel.executeSearch() }
                    } label: {
                        HStack(spacing: 6) {
                            if searchModel.isSearching {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text("Search")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(searchModel.isSearching)
                    .keyboardShortcut(.return, modifiers: .command)

                    Button("Reset") {
                        searchModel.resetForm()
                    }
                    .buttonStyle(.bordered)
                    .disabled(searchModel.isSearching)

                    Spacer()

                    if let error = searchModel.searchError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

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
    }
}
