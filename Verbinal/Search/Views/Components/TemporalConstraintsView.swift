// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct TemporalConstraintsView: View {
    @Bindable var formState: SearchFormState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Temporal")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Observation Date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. 2020..2021, > 2019", text: $formState.observationDate)
                    .textFieldStyle(.roundedBorder)
                Picker("Preset", selection: $formState.datePreset) {
                    ForEach(DatePresetValue.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
            }

            ConstraintField(label: "Integration Time", value: $formState.integrationTime, hint: "e.g. 100..500s")
            ConstraintField(label: "Time Span", value: $formState.timeSpan, hint: "e.g. > 1d")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
    }
}
