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
            // Shared registry + credentials UI (see RegistryCredentialsSection).
            // Only the UI is shared — this tab keeps its own service and its
            // own SEPARATE Keychain keystore.
            RegistryCredentialsSection(
                registryHost: $registryHost,
                username: $username,
                secret: $secret,
                saveError: $saveError,
                saveSuccess: $saveSuccess,
                isTestingCredentials: $isTestingCredentials,
                testResult: $testResult,
                savedRegistryHost: service.settings.registryHost,
                savedUsername: service.settings.username,
                hasSecret: service.settings.hasSecret,
                onSaveRegistryHost: saveRegistryHost,
                onSaveUsername: saveUsername,
                onSaveSecret: saveSecret,
                onClearSecret: clearSecret,
                onTestConnection: testCredentials
            )
            inspectorSection
            cacheSection
            footerSection
        }
        .formStyle(.grouped)
        .onAppear { hydrateFromService() }
        .alert("Reset Image Discovery settings?", isPresented: $resetConfirmShown) {
            Button("Reset", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the registry host, username, stored secret, and inspector-image override. Cached manifests on disk are not affected.")
        }
    }

    // MARK: - Sections

    /// Image Discovery package-manifest cache. Moved here from the AI
    /// Agent tab (it's a Discovery control). Shown only when the agent
    /// server is running and a discovery coordinator is alive — the
    /// same `isRunning` gating it had on the AI Agent tab, since probe
    /// jobs only run while the server is up.
    @ViewBuilder
    private var cacheSection: some View {
        if appState.agentsService.isRunning, let coord = appState.imageDiscoveryCoordinator {
            Section {
                ImageDiscoveryCacheRow(coordinator: coord)
            } header: {
                Text("Image Discovery Cache")
            } footer: {
                Text("Per-image package manifests learned by running " +
                     "small probe jobs inside Skaha containers. Stored at " +
                     "Application Support/Verbinal/ImageDiscovery/manifests/. " +
                     "Clearing wipes the local cache; in-flight probes will " +
                     "repopulate when they complete.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inspectorSection: some View {
        Section {
            HStack {
                TextField(
                    "Inspector image",
                    text: $inspectorImage,
                    prompt: Text(ImageDiscoverySettings.defaultInspectorImage)
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { saveInspectorImage() }
                Button("Save") { saveInspectorImage() }
                    .controlSize(.small)
                    .disabled(inspectorImage == service.settings.inspectorImage)
            }
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

/// Live cache count + a destructive Clear button for the Image
/// Discovery manifest cache. Moved here from the AI Agent tab (QW5) so
/// all Discovery controls live together. Loading state surfaces on the
/// initial fetch of `cacheCount()` so the user doesn't see "0 entries"
/// while the actor is hydrating.
fileprivate struct ImageDiscoveryCacheRow: View {
    let coordinator: ImageDiscoveryCoordinator
    @State private var count: Int? = nil
    @State private var clearing: Bool = false

    var body: some View {
        HStack {
            Label(label, systemImage: "shippingbox")
                .font(.callout)
            Spacer()
            Button("Clear", role: .destructive) {
                // Explicitly hop back to the main actor after each
                // await on the non-MainActor coordinator. Under
                // Swift 5.9 + SwiftUI the enclosing Task already
                // inherits MainActor isolation, so this is a no-op
                // today — but making it explicit documents the
                // contract and keeps the @State writes correct if
                // this closure is ever refactored out of the View
                // or the project enables Swift 6 strict concurrency.
                Task { @MainActor in
                    clearing = true
                    try? await coordinator.clearCache()
                    count = await coordinator.cacheCount()
                    clearing = false
                }
            }
            .controlSize(.small)
            .help("Drop every cached image manifest; in-flight probes keep running")
            .disabled(clearing || (count ?? 0) == 0)
        }
        .task { @MainActor in
            if count == nil {
                count = await coordinator.cacheCount()
            }
        }
    }

    private var label: String {
        switch count {
        case nil: return "Loading…"
        case .some(let n) where n == 1: return "1 entry"
        case .some(let n): return "\(n) entries"
        }
    }
}
#endif
