// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(iOS)
import SwiftUI

struct iOSAccountTab: View {
    @Environment(AppState.self) private var appState
    @State private var showAbout = false

    var body: some View {
        List {
            if let info = appState.userInfo {
                Section("Profile") {
                    if let first = info.firstName {
                        let name = [first, info.lastName].compactMap { $0 }.joined(separator: " ")
                        Label(name, systemImage: "person.fill")
                    }
                    if let email = info.email {
                        Label(email, systemImage: "envelope")
                    }
                    if let institute = info.institute {
                        Label(institute, systemImage: "building.2")
                    }
                }
            }

            Section {
                Button("About Verbinal") {
                    showAbout = true
                }
            }

            Section {
                Button("Logout", role: .destructive) {
                    Task { await appState.logout() }
                }
            }
        }
        .navigationTitle(appState.username)
        .sheet(isPresented: $showAbout) {
            AboutSheet()
        }
    }
}
#endif
