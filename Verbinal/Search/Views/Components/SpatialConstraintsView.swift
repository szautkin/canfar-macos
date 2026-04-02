// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct SpatialConstraintsView: View {
    @Bindable var formState: SearchFormState
    var resolverStatus: ResolverStatus
    var onTargetChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spatial")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Target / Coordinates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("e.g. M31, 10.68 41.27", text: $formState.target)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: formState.target) { _, _ in
                            onTargetChanged()
                        }
                    resolverStatusIndicator
                }
            }

            Picker("Resolver", selection: $formState.resolver) {
                ForEach(ResolverValue.allCases) { resolver in
                    Text(resolver.rawValue).tag(resolver)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: formState.resolver) { _, _ in
                onTargetChanged()
            }

            ConstraintField(label: "Pixel Scale", value: $formState.pixelScale, hint: "e.g. 0.5..2 arcsec")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
    }

    @ViewBuilder
    private var resolverStatusIndicator: some View {
        switch resolverStatus {
        case .idle:
            EmptyView()
        case .resolving:
            ProgressView()
                .scaleEffect(0.7)
        case .resolved(let ra, let dec):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Resolved: RA \(ra), Dec \(dec)")
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(msg)
        }
    }
}
