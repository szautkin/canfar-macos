// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

#if os(macOS)
extension ContentView {

    func makeLandingToolbar(showAbout: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            Text("Verbinal")
                .font(.headline)
            Text("- a CANFAR Science Portal")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if !appState.statusMessage.isEmpty {
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                showAbout.wrappedValue = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    func makeModeToolbar(title: String, showAbout: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Button {
                appState.currentMode = .landing
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)

            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            Text("Verbinal")
                .font(.headline)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                showAbout.wrappedValue = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    func makePortalToolbar(showAbout: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Button {
                appState.currentMode = .landing
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)

            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            Text("Verbinal")
                .font(.headline)
            Text("- a CANFAR Science Portal")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(appState.statusMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                showAbout.wrappedValue = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)

            if appState.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            }

            if appState.isAuthenticated {
                Menu {
                    if let info = appState.userInfo {
                        Section {
                            Text(info.email ?? "")
                            if let inst = info.institute {
                                Text(inst)
                            }
                        }
                    }
                    Divider()
                    Button("Logout") {
                        Task { await appState.logout() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.circle.fill")
                        if let info = appState.userInfo,
                           let first = info.firstName {
                            Text([first, info.lastName].compactMap { $0 }.joined(separator: " "))
                        } else {
                            Text(appState.username)
                        }
                    }
                }
            } else {
                Button("Login") {
                    appState.showLoginSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
#endif
