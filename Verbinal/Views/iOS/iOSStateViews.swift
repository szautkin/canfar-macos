// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(iOS)
import SwiftUI

/// The stored session being checked (or renewed) at launch: what the
/// Mac's toolbar says, as the whole screen (plan 47 0.4).
struct iOSSignInCheckView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(appState.statusMessage.isEmpty ? String(localized: "Validating session…") : appState.statusMessage)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Mac screen asked for on iOS.
struct iOSMacOnlyPlaceholder: View {
    let feature: LocalizedStringResource
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "desktopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("\(String(localized: feature)) is available on macOS")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Go Back") { appState.navigateBack() }
                .buttonStyle(.bordered)
            Spacer()
        }
    }
}
#endif
