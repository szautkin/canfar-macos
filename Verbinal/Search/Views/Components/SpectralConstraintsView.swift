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
                .help("Wavelength range of the observation. Units: nm, um, mm, cm, m, Hz, A, eV")
            ConstraintField(label: "Spectral Sampling", value: $formState.spectralSampling, hint: "e.g. > 1nm")
                .help("Spectral resolution element size. Smaller = higher resolution")
            ConstraintField(label: "Resolving Power", value: $formState.resolvingPower, hint: "e.g. 1000..5000")
                .help("Dimensionless ratio: wavelength / resolution element. Higher = finer spectral detail")
            ConstraintField(label: "Bandpass Width", value: $formState.bandpassWidth, hint: "e.g. < 100nm")
                .help("Total width of the wavelength range covered by the filter")
            ConstraintField(label: "Rest-frame Energy", value: $formState.restFrameEnergy, hint: "e.g. 5keV")
                .help("Observation energy in the rest frame. Units: eV, keV, MeV, GeV")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
    }
}
