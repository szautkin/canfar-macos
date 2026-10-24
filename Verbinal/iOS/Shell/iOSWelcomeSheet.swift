// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The welcome on iPhone and iPad (plan 50): one card, not a tour, after the
/// Terms. What works without an account comes first; then what an account
/// adds. Get Started closes it; Sign In swaps it for the sign-in sheet in
/// place (the single-sheet host's idiom, as the Mac's welcome does).
struct iOSWelcomeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WelcomePreferences.seenVersionKey) private var seenVersion = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(iOSWelcomeItem.rows(needingAccount: false)) { row($0) }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("With a CANFAR account")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .textCase(.uppercase)
                    ForEach(iOSWelcomeItem.rows(needingAccount: true)) { row($0) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 16)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { actions }
        // However it closes — a button, or a swipe down — it has been seen.
        .onDisappear { seenVersion = WelcomePreferences.currentVersion }
        .iosSheetChrome()
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("Welcome to Verbinal")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Look at astronomical data, no account needed.")
                .font(.title3)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ item: iOSWelcomeItem) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: item.symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text("Get Started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if !appState.isAuthenticated {
                Button("Sign In to CANFAR") {
                    seenVersion = WelcomePreferences.currentVersion
                    // Swap in place: dismissing first would race the reassignment.
                    appState.activeSheet = .login
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
