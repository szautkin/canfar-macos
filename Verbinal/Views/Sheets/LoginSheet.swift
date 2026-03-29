// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

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
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
            }
            .frame(maxWidth: 260)

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
        .sheetFrame(width: 360)
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
