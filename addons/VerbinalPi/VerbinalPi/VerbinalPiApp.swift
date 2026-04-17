// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import os.log
import VerbinalKit

private let logger = Logger(subsystem: "com.codebg.Verbinal.addon.notebook", category: "App")

/// Verbinal Pi — Notebook addon app.
///
/// This is a standalone macOS app that ships independently from the Verbinal
/// host on the Mac App Store. It registers itself as a member of the
/// Verbinal app family via:
///   - Bundle ID prefix `com.codebg.Verbinal.addon.notebook`
///   - A manifest baked into `Contents/Resources/VerbinalAddon.plist` that
///     the host reads via `AddonRegistry.discoverInstalled()`.
///   - The `verbinal-notebook://activate?ctx=…` URL scheme the host opens
///     when the user taps the Notebook tile.
///   - The shared Keychain access group `A4ABW5VD88.codebg.verbinal.family`,
///     so the user's CADC token — stored by the host — is readable here
///     without a second login prompt.
@main
struct VerbinalPiApp: App {

    @State private var tabHost: NotebookTabHostModel
    private let beacon: AddonBeacon

    init() {
        // Route Keychain through the shared family access group, so the token
        // the host wrote (under kSecAttrService = "com.codebg.Verbinal") is
        // visible to this addon without a second sign-in.
        KeychainStorage.configure(accessGroup: "A4ABW5VD88.codebg.verbinal.family")

        // Load the baked-in manifest from Contents/Resources/VerbinalAddon.plist
        // so host + addon agree on identity. The manifest is the same file
        // `AddonRegistry.discoverInstalled()` reads from this bundle.
        let manifest = Self.loadBakedManifest()
        self.beacon = AddonBeacon(manifest: manifest)
        _tabHost = State(initialValue: NotebookTabHostModel())
        logger.info("Verbinal Pi launched, manifest v\(manifest.version, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            PiRootView(tabHost: tabHost)
                .onOpenURL { url in
                    beacon.handleIncomingURL(url)
                }
                .task {
                    // Drain activation stream and dispatch to notebook tab host.
                    for await ctx in beacon.activations {
                        await handleActivation(ctx)
                    }
                }
        }
        .windowResizability(.contentSize)
    }

    // MARK: - Activation routing

    @MainActor
    private func handleActivation(_ context: AddonActivationContext) async {
        switch context {
        case .launchEmpty:
            // Nothing to do — welcome screen appears when tabs.isEmpty.
            break

        case .openFile(let url):
            openSecurityScopedFile(url)

        case .openSkyCoordinate(let ra, let dec, _, let fileURL):
            // Future: pre-populate a cone-search / cutout cell. For now,
            // log and open the attached file if present.
            logger.info("Activation with sky coord RA=\(ra) Dec=\(dec); will open \(fileURL?.lastPathComponent ?? "—", privacy: .public)")
            if let fileURL {
                openSecurityScopedFile(fileURL)
            }

        case .custom(let payload):
            logger.info("Custom activation payload: keys=\(payload.keys.joined(separator: ","), privacy: .public)")
        }
    }

    /// Open a URL received in an activation payload with security-scoped resource
    /// balancing. The `stopAccessing…` call must match `startAccessing…`; without
    /// it the kernel leaks the access grant.
    @MainActor
    private func openSecurityScopedFile(_ url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            try tabHost.openFile(url: url)
        } catch {
            tabHost.lastError = error.localizedDescription
        }
    }

    // MARK: - Manifest loading

    private static func loadBakedManifest() -> AddonManifest {
        // Hard-coded fallback used only if the plist resource is missing
        // (local dev builds without the Copy-File build phase wired up).
        // Production builds always resolve through the bundle.
        let fallback = AddonManifest(
            addonID: "com.codebg.Verbinal.addon.notebook",
            displayName: "Notebook",
            subtitle: "Run Jupyter notebooks locally",
            systemIconName: "terminal",
            urlScheme: "verbinal-notebook",
            version: "1.0.0",
            minimumHostVersion: "1.2.0",
            capabilities: [
                .viewer(fileTypes: ["public.python-script", "public.json"]),
                .producer
            ],
            authRequirement: .cadcOptional,
            trust: .official(
                teamID: "A4ABW5VD88",
                keychainAccessGroup: "A4ABW5VD88.codebg.verbinal.family"
            ),
            appStoreID: nil
        )

        guard
            let url = Bundle.main.url(forResource: "VerbinalAddon", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let decoded = try? PropertyListDecoder().decode(AddonManifest.self, from: data)
        else {
            logger.warning("Falling back to hard-coded manifest (plist not in bundle)")
            return fallback
        }
        return decoded
    }
}

// MARK: - Root view

struct PiRootView: View {
    var tabHost: NotebookTabHostModel

    var body: some View {
        NotebookRootView(tabHost: tabHost)
            .frame(minWidth: 800, minHeight: 600)
    }
}
