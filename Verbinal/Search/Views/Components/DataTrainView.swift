// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct DataTrainView: View {
    var dataTrainModel: DataTrainModel
    @Bindable var formState: SearchFormState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Additional Constraints")
                    .font(.headline)

                if dataTrainModel.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                Spacer()

                if let date = dataTrainModel.lastRefreshed {
                    Text("Updated \(date, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    Task { await dataTrainModel.refreshData() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(dataTrainModel.isRefreshing)
                .help("Refresh data train from CADC")
            }

            if dataTrainModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading data train...")
                    Spacer()
                }
                .frame(height: 120)
            } else if dataTrainModel.hasError {
                HStack {
                    Spacer()
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(dataTrainModel.errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(height: 120)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(ADQL.dataTrainColumns.enumerated()), id: \.offset) { index, column in
                            DataTrainColumnView(
                                title: ADQL.dataTrainColumnLabels[column] ?? column,
                                options: dataTrainModel.filteredOptions(for: index, formState: formState),
                                selection: selectionBinding(for: index),
                                onToggle: { value in
                                    dataTrainModel.toggleValue(value, at: index, formState: formState)
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
    }

    private func selectionBinding(for index: Int) -> [String] {
        switch index {
        case 0: return formState.selectedBands
        case 1: return formState.selectedCollections
        case 2: return formState.selectedInstruments
        case 3: return formState.selectedFilters
        case 4: return formState.selectedCalLevels
        case 5: return formState.selectedDataTypes
        case 6: return formState.selectedObsTypes
        default: return []
        }
    }
}
