// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ObservationConstraintsView: View {
    @Bindable var formState: SearchFormState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Observation")
                .font(.headline)

            ConstraintField(label: "Observation ID", value: $formState.observationID, hint: "e.g. ia5q06010 or ia*")
            ConstraintField(label: "P.I. Name", value: $formState.piName, hint: "e.g. Abraham")
            ConstraintField(label: "Proposal ID", value: $formState.proposalID, hint: "e.g. 11095")
            ConstraintField(label: "Proposal Title", value: $formState.proposalTitle)
            ConstraintField(label: "Proposal Keywords", value: $formState.proposalKeywords)
            ConstraintField(label: "Data Release", value: $formState.dataRelease, hint: "e.g. 2020..2021")

            HStack {
                Toggle("Public only", isOn: $formState.publicOnly)
                    .toggleStyle(.checkbox)
                Spacer()
            }

            Picker("Intent", selection: $formState.intent) {
                ForEach(IntentValue.allCases) { intent in
                    Text(intent.displayName).tag(intent)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
    }
}
