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
    @State private var cores: Int = AIComputeSettings.defaultCores
    @State private var ram: Int = AIComputeSettings.defaultRam
    @State private var saveError: String?
    @State private var saveSuccess: Bool = false
    @State private var resetConfirmShown: Bool = false
    @State private var isTestingCredentials: Bool = false
    @State private var testResult: ImageDiscoverySettingsService.RegistryTestResult?

    private var service: AIComputeSettingsService { appState.aiComputeSettings }

    var body: some View {
        Form {
            computeImageSection
            resourcesSection
            // Shared registry + credentials UI (see RegistryCredentialsSection).
            // Only the UI is shared — AI Compute keeps its own service and its
            // own SEPARATE Keychain keystore from Image Discovery, hence the
            // footer note below.
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
                onTestConnection: testCredentials,
                credentialsFooterNote: "These credentials are stored separately from the Image Discovery tab's — setting one does not fill in the other."
            )
            footerSection
        }
        .formStyle(.grouped)
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

    // Resource option lists — prefer the live CANFAR session context
    // (the deployment's actual offered sizes), fall back to a static
    // menu when the cache hasn't loaded so the field is always usable.
    private var coreOptions: [Int] {
        let opts = appState.portalImageCacheService.cache?.context?.cores.options ?? []
        let base = opts.isEmpty ? [1, 2, 4, 8, 16] : opts
        // Always include the persisted value so the Picker has a matching tag.
        // The agent can size the instance via start_compute to a value the live
        // menu doesn't offer; without this the Picker would render blank.
        return Array(Set(base + [cores])).sorted()
    }
    private var ramOptions: [Int] {
        let opts = appState.portalImageCacheService.cache?.context?.memoryGB.options ?? []
        let base = opts.isEmpty ? [1, 2, 4, 8, 16, 32] : opts
        return Array(Set(base + [ram])).sorted()
    }

    private var resourcesSection: some View {
        Section {
            Picker("Cores", selection: $cores) {
                ForEach(coreOptions, id: \.self) { Text("\($0)").tag($0) }
            }
            .onChange(of: cores) { _, newValue in
                service.setCores(newValue)
                cores = service.settings.cores
            }

            Picker("RAM (GB)", selection: $ram) {
                ForEach(ramOptions, id: \.self) { Text("\($0)").tag($0) }
            }
            .onChange(of: ram) { _, newValue in
                service.setRam(newValue)
                ram = service.settings.ram
            }
        } header: {
            Text("Compute Resources")
        } footer: {
            Text("These size the run_code compute instance. Small/fast is best for quick checks — the smallest size schedules fastest. The available sizes come from your CANFAR session context; the agent can also pass a size to start_compute to override this default.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        cores = s.cores
        ram = s.ram
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
