// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// Settings ▸ Compute — the AI Remote Compute image + the registry
/// credentials used to pull it. Mirrors the Image Discovery tab's
/// registry/credentials block (one-way secret write, explicit Save,
/// Docker V2 token-auth Test Connection) for the `verbinal-execution`
/// compute image the agent `run_code` tool drives.
struct AIComputeSettingsTab: View {
    @Environment(AppState.self) private var appState

    @State private var registryHost: String = ""
    @State private var username: String = ""
    @State private var secret: String = ""
    @State private var image: String = ""
    @State private var saveError: String?
    @State private var saveSuccess: Bool = false
    @State private var resetConfirmShown: Bool = false
    @State private var isTestingCredentials: Bool = false
    @State private var testResult: ImageDiscoverySettingsService.RegistryTestResult?

    private var service: AIComputeSettingsService { appState.aiComputeSettings }

    var body: some View {
        Form {
            computeImageSection
            registrySection
            credentialsSection
            footerSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { hydrateFromService() }
        .alert("Reset AI Remote Compute settings?", isPresented: $resetConfirmShown) {
            Button("Reset", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the compute image, registry host, username, and stored secret used by the agent run_code tool.")
        }
    }

    // MARK: - Sections

    private var computeImageSection: some View {
        Section {
            HStack {
                TextField(
                    "Compute image",
                    text: $image,
                    prompt: Text("e.g. images.canfar.net/project/verbinal-compute:1.0")
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { saveImage() }
                Button("Save") { saveImage() }
                    .controlSize(.small)
                    .disabled(image == service.settings.image)
            }
        } header: {
            Text("AI Remote Compute")
        } footer: {
            Text("Container image launched as a contributed interactive session so the AI agent can run code on the fast interactive pool, skipping the headless batch queue. Must be registered in Harbor for the contributed session type. Leave empty to disable the run_code tool.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var registrySection: some View {
        Section {
            HStack {
                TextField("Registry host", text: $registryHost, prompt: Text("images.canfar.net"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { saveRegistryHost() }
                Button("Save") { saveRegistryHost() }
                    .controlSize(.small)
                    .disabled(registryHost == service.settings.registryHost)
            }
        } header: {
            Text("Registry")
        } footer: {
            Text("Container registry the credentials below authenticate against, for pulling the AI compute image. Default is the CANFAR Harbor host; other registries (Docker Hub, Quay, GHCR) work too.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var credentialsSection: some View {
        Section {
            HStack {
                TextField("Username", text: $username, prompt: Text("CADC username"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { saveUsername() }
                Button("Save") { saveUsername() }
                    .controlSize(.small)
                    .disabled(username == service.settings.username)
            }

            SecureField("Secret", text: $secret, prompt: Text(service.settings.hasSecret ? "•••••••• (set)" : "Harbor CLI secret"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                if service.settings.hasSecret {
                    Button("Remove Secret", role: .destructive) { clearSecret() }
                        .controlSize(.small)
                }
                Button("Save Secret") { saveSecret() }
                    .controlSize(.small)
                    .disabled(secret.isEmpty || username.isEmpty)
                Button(action: testCredentials) {
                    if isTestingCredentials {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test Connection")
                    }
                }
                .controlSize(.small)
                .disabled(isTestingCredentials
                          || registryHost.trimmingCharacters(in: .whitespaces).isEmpty
                          || username.trimmingCharacters(in: .whitespaces).isEmpty
                          || !service.settings.hasSecret)
                .help("Verify the stored credentials by performing the Docker Registry V2 token-auth flow against the configured host.")
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if saveSuccess {
                Label("Secret saved to Keychain.", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let testResult {
                testResultLabel(testResult)
            }
        } header: {
            Text("Credentials")
        } footer: {
            Text("Stored in the macOS Keychain. Used to build the `x-skaha-registry-auth` header so Skaha can pull a private compute image when run_code launches the session. The secret is never read back — set or clear, not view. Click **Test Connection** to verify before launching.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func testResultLabel(_ result: ImageDiscoverySettingsService.RegistryTestResult) -> some View {
        switch result {
        case .success(let message):
            Label { Text(message).textSelection(.enabled) } icon: { Image(systemName: "checkmark.seal.fill") }
                .font(.caption).foregroundStyle(.green)
        case .unauthorized:
            Label {
                Text("Harbor rejected these credentials. Common cause: you entered your CADC password instead of the Harbor CLI secret (copy it from your Harbor user profile).")
                    .textSelection(.enabled)
            } icon: { Image(systemName: "xmark.octagon.fill") }
                .font(.caption).foregroundStyle(.red)
        case .missingConfiguration(let reason):
            Label { Text(reason).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(.caption).foregroundStyle(.orange)
        case .invalidChallenge(let message):
            Label {
                Text("Registry didn't return a recognisable auth challenge: \(message)").textSelection(.enabled)
            } icon: { Image(systemName: "questionmark.diamond.fill") }
                .font(.caption).foregroundStyle(.orange)
        case .networkError(let message):
            Label {
                Text("Couldn't reach the registry: \(message)").textSelection(.enabled)
            } icon: { Image(systemName: "wifi.exclamationmark") }
                .font(.caption).foregroundStyle(.red)
        }
    }

    private var footerSection: some View {
        Section {
            HStack {
                Spacer()
                Button("Reset to Defaults", role: .destructive) { resetConfirmShown = true }
                    .controlSize(.small)
                    .disabled(service.settings.isAllDefaults)
            }
        }
    }

    // MARK: - Actions

    private func hydrateFromService() {
        let s = service.settings
        registryHost = s.registryHost
        username = s.username
        image = s.image
        secret = ""
        saveError = nil
        saveSuccess = false
        testResult = nil
    }

    private func saveImage() {
        service.setImage(image)
        image = service.settings.image
    }

    private func saveRegistryHost() {
        service.setRegistryHost(registryHost)
        registryHost = service.settings.registryHost
        testResult = nil
    }

    private func saveUsername() {
        service.setUsername(username)
        username = service.settings.username
        testResult = nil
    }

    private func testCredentials() {
        if registryHost != service.settings.registryHost { saveRegistryHost() }
        if username != service.settings.username { saveUsername() }
        isTestingCredentials = true
        testResult = nil
        Task {
            let result = await service.testRegistryCredentials()
            self.testResult = result
            self.isTestingCredentials = false
        }
    }

    private func saveSecret() {
        if registryHost != service.settings.registryHost { saveRegistryHost() }
        if username != service.settings.username { saveUsername() }
        do {
            try service.setSecret(secret)
            secret = ""
            saveError = nil
            saveSuccess = true
            testResult = nil
        } catch {
            saveError = error.localizedDescription
            saveSuccess = false
        }
    }

    private func clearSecret() {
        do {
            try service.clearSecret()
            saveError = nil
            saveSuccess = false
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func resetAll() {
        do {
            try service.resetToDefaults()
            hydrateFromService()
            saveError = nil
            saveSuccess = false
        } catch {
            saveError = error.localizedDescription
        }
    }
}
#endif
