// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI

/// Shared registry-host + credentials UI for the Image Discovery and
/// AI Compute Settings tabs.
///
/// Both tabs authenticate a Harbor/OCI host with the same one-way
/// secret model (SecureField + explicit Save/Remove, never read back)
/// and the same Docker Registry V2 token-auth "Test Connection" flow.
/// This view owns only that *UI*; the two features keep their own
/// services and — critically — their own SEPARATE Keychain keystores.
/// The host view passes per-feature behaviour via closures so nothing
/// about where the secret lives is unified here.
///
/// `RegistryTestResult` is the already-shared
/// `ImageDiscoverySettingsService.RegistryTestResult` (AI Compute
/// reuses it), so the inline result label is genuinely common.
struct RegistryCredentialsSection: View {
    /// Edit buffers + transient UI state live in the host view (so it
    /// can hydrate / reset them); we bind to them here.
    @Binding var registryHost: String
    @Binding var username: String
    @Binding var secret: String
    @Binding var saveError: String?
    @Binding var saveSuccess: Bool
    @Binding var isTestingCredentials: Bool
    @Binding var testResult: ImageDiscoverySettingsService.RegistryTestResult?

    /// The host the persisted secret authenticates against. The Save
    /// buttons compare the buffer against these to disable when clean.
    let savedRegistryHost: String
    let savedUsername: String
    let hasSecret: Bool

    /// Per-feature persistence — closures so the two SEPARATE services
    /// (and their two SEPARATE keystores) stay fully intact behind a
    /// shared UI.
    let onSaveRegistryHost: () -> Void
    let onSaveUsername: () -> Void
    let onSaveSecret: () -> Void
    let onClearSecret: () -> Void
    let onTestConnection: () -> Void

    /// Optional footer appended after the shared credentials footer —
    /// AI Compute uses it to note its credentials are stored separately
    /// from Image Discovery.
    var credentialsFooterNote: String? = nil

    var body: some View {
        registrySection
        credentialsSection
    }

    // MARK: - Sections

    private var registrySection: some View {
        Section {
            HStack {
                TextField("Registry host", text: $registryHost, prompt: Text("images.canfar.net"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { onSaveRegistryHost() }
                Button("Save") { onSaveRegistryHost() }
                    .controlSize(.small)
                    .disabled(registryHost == savedRegistryHost)
            }
        } header: {
            Text("Registry")
        } footer: {
            Text("Container registry the credentials below authenticate against. Default is the CANFAR Harbor host. Other registries (Docker Hub, Quay, GHCR) work too — set the host to match the image's prefix.")
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
                    .onSubmit { onSaveUsername() }
                Button("Save") { onSaveUsername() }
                    .controlSize(.small)
                    .disabled(username == savedUsername)
            }

            SecureField("Secret", text: $secret, prompt: Text(hasSecret ? "•••••••• (set)" : "Harbor CLI secret"))
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                if hasSecret {
                    Button("Remove Secret", role: .destructive) { onClearSecret() }
                        .controlSize(.small)
                }
                Button("Save Secret") { onSaveSecret() }
                    .controlSize(.small)
                    .disabled(secret.isEmpty || username.isEmpty)
                Button(action: onTestConnection) {
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
                          || !hasSecret)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Stored in the macOS Keychain. Used to build the `x-skaha-registry-auth` header so Skaha can pull from private namespaces. The secret itself is never read back into this dialog — set or clear, not view. Click **Test Connection** to verify the credentials reach the registry first.")
                if let credentialsFooterNote {
                    Text(credentialsFooterNote)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// Render a result row matching the case. Icon + colour communicate
    /// at a glance; the message text gives the reason.
    /// `textSelection(.enabled)` so the user can paste the error into a
    /// bug report. `.accessibilityLabel` surfaces the outcome to
    /// VoiceOver, not just the colour.
    @ViewBuilder
    private func testResultLabel(_ result: ImageDiscoverySettingsService.RegistryTestResult) -> some View {
        switch result {
        case .success(let message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .accessibilityLabel("Connection succeeded")
            }
            .font(.caption)
            .foregroundStyle(.green)

        case .unauthorized:
            Label {
                Text("Harbor rejected these credentials. Common cause: you entered your CADC password instead of the Harbor CLI secret (copy it from your Harbor user profile).")
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .accessibilityLabel("Connection rejected")
            }
            .font(.caption)
            .foregroundStyle(.red)

        case .missingConfiguration(let reason):
            Label {
                Text(reason).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityLabel("Configuration incomplete")
            }
            .font(.caption)
            .foregroundStyle(.orange)

        case .invalidChallenge(let message):
            Label {
                Text("Registry didn't return a recognisable auth challenge: \(message)")
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "questionmark.diamond.fill")
                    .accessibilityLabel("Unexpected registry response")
            }
            .font(.caption)
            .foregroundStyle(.orange)

        case .networkError(let message):
            Label {
                Text("Couldn't reach the registry: \(message)")
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .accessibilityLabel("Network error")
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }
}
#endif
