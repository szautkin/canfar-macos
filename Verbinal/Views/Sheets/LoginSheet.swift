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

struct LoginSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var rememberMe = true
    @State private var isLoggingIn = false
    @State private var errorMessage = ""
    @State private var hasError = false

    var body: some View {
        VStack(spacing: 20) {
            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)

            Text("Login to CANFAR")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit { Task { await login() } }

                Toggle("Remember me", isOn: $rememberMe)
                    .toggleStyle(.checkbox)
            }
            .frame(width: 260)

            if hasError {
                Label(errorMessage, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isLoggingIn {
                ProgressView("Authenticating...")
            }

            HStack(spacing: 16) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Login") {
                    Task { await login() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isLoggingIn || username.isEmpty || password.isEmpty)
            }
        }
        .padding(32)
        .frame(width: 360)
    }

    private func login() async {
        isLoggingIn = true
        hasError = false

        let result = await appState.authService.login(
            username: username,
            password: password,
            rememberMe: rememberMe
        )

        if result.success {
            appState.updateAuthState(
                username: result.username ?? username,
                userInfo: result.userInfo
            )
            dismiss()
        } else {
            hasError = true
            errorMessage = result.errorMessage ?? "Login failed"
        }

        isLoggingIn = false
    }
}
