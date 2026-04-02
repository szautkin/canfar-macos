// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SpectralConstraintsView: View {
    @Bindable var formState: SearchFormState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spectral")
                .font(.headline)

            ConstraintField(label: "Spectral Coverage", value: $formState.spectralCoverage, hint: "e.g. 400..700nm")
            ConstraintField(label: "Spectral Sampling", value: $formState.spectralSampling, hint: "e.g. > 1nm")
            ConstraintField(label: "Resolving Power", value: $formState.resolvingPower, hint: "e.g. 1000..5000")
            ConstraintField(label: "Bandpass Width", value: $formState.bandpassWidth, hint: "e.g. < 100nm")
            ConstraintField(label: "Rest-frame Energy", value: $formState.restFrameEnergy, hint: "e.g. 5keV")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
    }
}
