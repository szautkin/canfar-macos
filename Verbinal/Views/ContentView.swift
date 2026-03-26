// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showAbout = false

    var body: some View {
        VStack(spacing: 0) {
            toolbarView
            Divider()

            if appState.isAuthenticated {
                DashboardView()
            } else if appState.isLoading {
                Spacer()
                ProgressView("Checking authentication...")
                Spacer()
            } else {
                Spacer()
                VStack(spacing: 16) {
                    Image("VerbinalIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                    Text("Welcome to Verbinal")
                        .font(.title)
                    Text("A CANFAR Science Portal Companion")
                        .foregroundStyle(.secondary)
                    Text(appState.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Login") {
                        appState.showLoginSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Spacer()
            }
        }
        .sheet(isPresented: Bindable(appState).showLoginSheet) {
            LoginSheet()
        }
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
        .task {
            await appState.initialize()
        }
    }

    @ViewBuilder
    private var toolbarView: some View {
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

            Text(appState.statusMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                showAbout = true
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
                        Text(appState.username)
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
