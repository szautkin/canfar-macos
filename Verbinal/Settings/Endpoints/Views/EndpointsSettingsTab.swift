// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import SwiftUI
import VerbinalKit

/// Settings ▸ Endpoints — every CANFAR/CADC service base URL the app
/// talks to, with its effective value and where that value came from
/// (user override > registry resolution > CANFAR default), plus the
/// registry-refresh status and controls.
///
/// Edits use local buffers committed on submit (never bound raw to the
/// service), and take effect on relaunch — services capture their
/// endpoints at launch, so the restart banner mirrors the General tab's
/// language pattern.
struct EndpointsSettingsTab: View {
    @Environment(AppState.self) private var appState

    /// Local edit buffers, keyed by field. Committed on submit; seeded
    /// from the stored overrides on appear.
    @State private var buffers: [EndpointField: String] = [:]
    @State private var invalidFields: Set<EndpointField> = []
    @State private var resetConfirmShown = false

    /// Self-test state: true while probes are in flight, plus the last
    /// per-service reachability snapshot from the shared probe engine.
    @State private var isTesting = false
    @State private var testResults: [GetServiceHealthTool.Output.Service] = []

    private var settings: EndpointSettingsService { appState.endpointSettings }
    private var registry: EndpointRegistryService { appState.endpointRegistry }

    var body: some View {
        Form {
            registrySection
            endpointsSection(
                title: "Authentication",
                fields: [.loginBaseURL, .acBaseURL],
                footer: "The login service validates CADC credentials; the account service backs the science platform."
            )
            endpointsSection(
                title: "Science Platform",
                fields: [.skahaBaseURL, .storageBaseURL],
                footer: "Skaha launches sessions; the storage base is the VOSpace nodes root the file browser starts from."
            )
            endpointsSection(
                title: "Archive & Data",
                fields: [.archiveBaseURL, .externalBaseURL],
                footer: "The archive base hosts TAP (argus), CAOM2 metadata, DataLink, and direct downloads. External URLs open in the browser."
            )
            resetSection
            testConnectionsSection
            if settings.pendingRelaunch || registry.resolvedChangesPendingRelaunch {
                relaunchSection
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: seedBuffers)
    }

    // MARK: - Registry status + its own endpoint

    private var registrySection: some View {
        Section {
            endpointRow(for: .registryBaseURL)

            HStack(spacing: 10) {
                switch registry.refreshState {
                case .refreshing:
                    ProgressView()
                        .controlSize(.small)
                    Text("Contacting the registry…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .idle:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let cached = registry.cached {
                        Text("Resolved \(cached.perService.count) services \(cached.fetchedAt, format: .relative(presentation: .named)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not resolved yet — using configured values.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Refresh Now") {
                    Task { await registry.refresh() }
                }
                .controlSize(.small)
                .disabled(registry.refreshState == .refreshing)
            }

            if let warnings = registry.cached?.warnings, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("IVOA Registry")
        } footer: {
            Text("Service locations are pulled from the registry's resource-caps document, cached locally, and re-checked daily. Overrides always win over resolved values.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Endpoint groups

    private func endpointsSection(title: String, fields: [EndpointField], footer: String) -> some View {
        Section {
            ForEach(fields) { field in
                endpointRow(for: field)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func endpointRow(for field: EndpointField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(
                    field.title,
                    text: bufferBinding(for: field),
                    prompt: Text(field.defaultValue)
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { commit(field) }

                if settings.overrides[field] != nil {
                    Button {
                        settings.clearOverride(for: field)
                        buffers[field] = ""
                        invalidFields.remove(field)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the override and fall back to the resolved/default value")
                    .accessibilityLabel("Clear override")
                }
            }

            HStack(spacing: 6) {
                sourceBadge(for: field)
                Text(registry.effectiveValue(for: field))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if invalidFields.contains(field) {
                Text("Enter a full http(s) URL, e.g. \(field.defaultValue)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func sourceBadge(for field: EndpointField) -> some View {
        let source = registry.source(for: field)
        let (label, tint): (String, Color) = switch source {
        case .override: ("Override", .orange)
        case .resolved: ("Resolved", .blue)
        case .defaultValue: ("Default", .secondary)
        }
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    // MARK: - Reset + relaunch

    private var resetSection: some View {
        Section {
            Button("Reset All to Defaults", role: .destructive) {
                resetConfirmShown = true
            }
            .confirmationDialog(
                "Remove all endpoint overrides?",
                isPresented: $resetConfirmShown
            ) {
                Button("Reset All", role: .destructive) {
                    settings.resetToDefaults()
                    buffers = [:]
                    invalidFields = []
                }
            } message: {
                Text("Registry-resolved values and CANFAR defaults will apply after the next launch.")
            }
        }
    }

    private var relaunchSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart required")
                        .font(.callout.bold())
                    Text("Endpoints are applied at launch. Restart Verbinal to use the new values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restart Now") {
                    appState.relaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Test connections

    /// Self-test: probe every configured deployment endpoint for
    /// reachability + latency, reusing the same engine that backs the
    /// `get_service_health` MCP tool. Scope is the configured deployment
    /// services only — the global VizieR mirrors are excluded (matching the
    /// Windows client's self-test scope).
    private var testConnectionsSection: some View {
        Section {
            HStack(spacing: 10) {
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Probing endpoints…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if testResults.isEmpty {
                    Text("Not tested yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Probed \(testResults.count) services.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Test Connections") {
                    runConnectionTests()
                }
                .controlSize(.small)
                .disabled(isTesting)
            }

            ForEach(testResults, id: \.name) { result in
                testResultRow(result)
            }
        } header: {
            Text("Test Connections")
        } footer: {
            Text("Probes each service's /availability endpoint for reachability. Reflects the saved/effective values services use at the next launch, not unsaved edits. VizieR mirrors are excluded.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func testResultRow(_ result: GetServiceHealthTool.Output.Service) -> some View {
        HStack(spacing: 8) {
            statusPill(for: result.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.caption)
                Text(result.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if let latency = result.latencyMs {
                Text("\(latency) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    /// Colored status pill — same capsule treatment as `sourceBadge`.
    /// `status` is the engine's raw string: `ok` / `degraded` / `down`.
    private func statusPill(for status: String) -> some View {
        let (label, tint): (String, Color) = switch status {
        case "ok": ("OK", .green)
        case "degraded": ("Degraded", .orange)
        case "skipped": ("Skipped", .secondary)
        default: ("Down", .red)
        }
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private func runConnectionTests() {
        guard !isTesting else { return }
        isTesting = true
        testResults = []
        // Scope to the configured deployment services only, dropping the
        // deployment-independent VizieR mirrors. `Endpoint` is Equatable, so
        // the mirror list filters cleanly. Probe the effective (saved) values
        // — the ones services will capture at the next launch.
        let mirrors = GetServiceHealthTool.vizierMirrors
        let endpoints = GetServiceHealthTool
            .deploymentEndpoints(for: registry.effectiveEndpoints())
            .filter { !mirrors.contains($0) }
        Task {
            let output = await GetServiceHealthTool.runCanonicalProbes(endpoints: endpoints)
            await MainActor.run {
                testResults = output.services
                isTesting = false
            }
        }
    }

    // MARK: - Buffer plumbing

    private func seedBuffers() {
        for field in EndpointField.allCases where buffers[field] == nil {
            buffers[field] = settings.overrides[field] ?? ""
        }
    }

    private func bufferBinding(for field: EndpointField) -> Binding<String> {
        Binding(
            get: { buffers[field] ?? "" },
            set: { buffers[field] = $0 }
        )
    }

    private func commit(_ field: EndpointField) {
        let raw = buffers[field] ?? ""
        guard let normalized = EndpointOverrides.normalize(raw) else {
            // Blank = clear the override.
            settings.clearOverride(for: field)
            invalidFields.remove(field)
            return
        }
        guard EndpointOverrides.isValidBase(normalized) else {
            invalidFields.insert(field)
            return
        }
        invalidFields.remove(field)
        settings.setOverride(normalized, for: field)
    }
}
#endif
