// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

struct LoginSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var rememberMe = true
    @State private var didPrefill = false
    /// The sign-in (plan 38): under way, done, or why not.
    @State private var signIn: Phase<String> = .idle
    private var isLoggingIn: Bool { signIn.isWorking }

    private enum Field {
        case username, password
    }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 20) {
            Image("VerbinalIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)

            Text("Log In to CANFAR")
                .font(.title2)
                .fontWeight(.semibold)

            if let reason = appState.auth.signInReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }

            VStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    // A CADC username as typed: iOS would capitalize its first letter.
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($focusedField, equals: .username)

                PasswordField("Password", text: $password, focus: $focusedField, field: .password) {
                    Task { await login() }
                }

                Toggle("Remember me", isOn: $rememberMe)
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
            }
            .frame(maxWidth: 260)

            if let problem = signIn.problem {
                Label(problem.message, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isLoggingIn {
                ProgressView("Authenticating…")
            }

            HStack(spacing: 16) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Log In") {
                    Task { await login() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isLoggingIn || username.isEmpty || password.isEmpty)
            }
        }
        .padding(32)
        .sheetFrame(width: 360)
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            let (storedUsername, _) = KeychainStorage.loadCredentials()
            if let stored = storedUsername, !stored.isEmpty {
                username = stored
            }
            // Land the cursor where typing starts: the password field when a
            // stored username was pre-filled, the username field otherwise.
            focusedField = username.isEmpty ? .username : .password
        }
    }

    private func login() async {
        // Return in the password field submits it, and Return is also Log
        // In's shortcut: one key could send two sign-ins.
        guard !isLoggingIn, !username.isEmpty, !password.isEmpty else { return }
        let attempt = signIn.begin()

        let result = await appState.authService.login(
            username: username,
            password: password,
            rememberMe: rememberMe
        )

        if result.success {
            let name = result.username ?? username
            signIn.finish(attempt, with: .success(name))
            appState.updateAuthState(username: name, userInfo: result.userInfo)
            dismiss()
        } else {
            // A wrong password is for the person to put right, not to try again.
            signIn.finish(attempt, with: .failure(Problem(.refused, result.errorMessage ?? String(localized: "Login failed"), retry: false)))
        }
    }
}
