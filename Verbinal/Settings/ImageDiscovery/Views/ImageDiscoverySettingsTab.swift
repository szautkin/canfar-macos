// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// Settings ▸ Image Discovery — registry credentials + inspector
/// image override.
///
/// Layout: three sections matching the three knobs on
/// `ImageDiscoverySettings`. Secret is a one-way write (SecureField
/// + Save button); we deliberately don't surface the stored value
/// for read-back so the Keychain stays the only authoritative
/// place the secret lives.
struct ImageDiscoverySettingsTab: View {
    @Environment(AppState.self) private var appState

    /// Local edit buffers. We don't bind directly to the service
    /// because the service publishes only AFTER persistence — a
    /// raw two-way binding would write on every keystroke. Local
    /// buffers + explicit Save on Return / blur match the macOS
    /// preferences convention.
    @State private var registryHost: String = ""
    @State private var username: String = ""
    @State private var secret: String = ""
    @State private var inspectorImage: String = ""
    @State private var saveError: String?
    @State private var saveSuccess: Bool = false
    @State private var resetConfirmShown: Bool = false

    /// Live state for the "Test Connection" affordance. The test
    /// runs the Docker Registry V2 token-auth dance against the
    /// configured Harbor host; the result renders inline beneath
    /// the credentials section so the user gets immediate
    /// feedback before submitting a real probe job.
    /// 2026-05-20 addition: catches the K8s ImagePullBackOff
    /// case (wrong CLI secret, wrong username) at credential
    /// entry time instead of five minutes later in the Pending
    /// queue.
    @State private var isTestingCredentials: Bool = false
    @State private var testResult: ImageDiscoverySettingsService.RegistryTestResult?

    private var service: ImageDiscoverySettingsService {
        appState.imageDiscoverySettings
    }

    var body: some View {
        Form {
            registrySection
            credentialsSection
            inspectorSection
            footerSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { hydrateFromService() }
        .alert("Reset Image Discovery settings?", isPresented: $resetConfirmShown) {
            Button("Reset", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the registry host, username, stored secret, and inspector-image override. Cached manifests on disk are not affected.")
        }
    }

    // MARK: - Sections

    private var registrySection: some View {
        Section {
            TextField("Registry host", text: $registryHost, prompt: Text("images.canfar.net"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { saveRegistryHost() }
        } header: {
            Text("Registry")
        } footer: {
            Text("Container registry the credentials below authenticate against. Default is the CANFAR Harbor host. Other registries (Docker Hub, Quay, GHCR) work too — set the host to match the inspector image's prefix.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Username", text: $username, prompt: Text("CADC username"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { saveUsername() }

            SecureField("Secret", text: $secret, prompt: Text(service.settings.hasSecret ? "•••••••• (set)" : "Harbor CLI secret"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                if service.settings.hasSecret {
                    Button("Remove Secret", role: .destructive) {
                        clearSecret()
                    }
                    .controlSize(.small)
                }
                Button("Save Secret") {
                    saveSecret()
                }
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
            Text("Stored in the macOS Keychain. Used to build the `x-skaha-registry-auth` header on probe jobs so Skaha can pull from private namespaces (canucs/, project-specific cadc/, …). The secret itself is never read back into this dialog — set or clear, not view. Click **Test Connection** to verify the credentials reach Harbor before submitting a probe job.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Render a result row matching the case. Icon + colour
    /// communicate at a glance; the message text gives the
    /// reason. `textSelection(.enabled)` so the user can paste
    /// the error into a bug report.
    @ViewBuilder
    private func testResultLabel(_ result: ImageDiscoverySettingsService.RegistryTestResult) -> some View {
        switch result {
        case .success(let message):
            Label {
                Text(message)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
            }
            .font(.caption)
            .foregroundStyle(.green)

        case .unauthorized:
            Label {
                Text("Harbor rejected these credentials. Common cause: you entered your CADC password instead of the Harbor CLI secret (copy it from your Harbor user profile).")
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
            }
            .font(.caption)
            .foregroundStyle(.red)

        case .missingConfiguration(let reason):
            Label {
                Text(reason)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.orange)

        case .invalidChallenge(let message):
            Label {
                Text("Registry didn't return a recognisable auth challenge: \(message)")
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "questionmark.diamond.fill")
            }
            .font(.caption)
            .foregroundStyle(.orange)

        case .networkError(let message):
            Label {
                Text("Couldn't reach the registry: \(message)")
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }

    private var inspectorSection: some View {
        Section {
            TextField(
                "Inspector image",
                text: $inspectorImage,
                prompt: Text(ImageDiscoverySettings.defaultInspectorImage)
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .onSubmit { saveInspectorImage() }
        } header: {
            Text("Inspector Image")
        } footer: {
            Text("Container image used as the host for inspector-mode probing. Must be headless-launchable and ship bash + python3 + curl. See docs/inspector-image.md for build requirements. Empty field reverts to the built-in default.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var footerSection: some View {
        Section {
            HStack {
                Spacer()
                Button("Reset to Defaults", role: .destructive) {
                    resetConfirmShown = true
                }
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
        inspectorImage = s.inspectorImage
        secret = ""
        saveError = nil
        saveSuccess = false
        // Stale test results would be misleading on re-open — if
        // the user came back to the tab, they get a fresh slate.
        testResult = nil
    }

    private func saveRegistryHost() {
        service.setRegistryHost(registryHost)
        registryHost = service.settings.registryHost
        // Any change invalidates the prior test result (creds
        // could now be authenticating against a different host).
        testResult = nil
    }

    private func saveUsername() {
        service.setUsername(username)
        username = service.settings.username
        testResult = nil
    }

    private func saveInspectorImage() {
        service.setInspectorImage(inspectorImage)
        inspectorImage = service.settings.inspectorImage
    }

    /// Run the registry credential test against the configured
    /// host. Persist any unsaved field edits first so the test
    /// uses the same `(host, username)` pair that the Keychain
    /// secret is filed under.
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
        // Make sure the username + host on screen are persisted
        // before we attempt the Keychain write — Keychain account
        // is built from the current service state, not the field.
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
