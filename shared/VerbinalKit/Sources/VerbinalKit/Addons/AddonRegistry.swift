// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log
#if os(macOS)
import AppKit
#endif

/// Host-side addon discovery and activation.
///
/// The host queries LaunchServices at launch for every application whose
/// bundle ID matches the first-party prefix `com.codebg.Verbinal.addon.` and,
/// for each hit, reads its `VerbinalAddon.plist` (inside the installed addon's
/// `Contents/Resources/`) to recover the manifest.
///
/// Community addons are not yet supported in this build — they will drop their
/// manifest into an App Group container in a later phase.
/// Bundle-ID prefix every first-party addon must claim.
public let officialAddonBundleIDPrefix = "com.codebg.Verbinal.addon."

/// Filename of the manifest the addon bakes into its Contents/Resources.
public let verbinalAddonManifestResourceName = "VerbinalAddon"
public let verbinalAddonManifestResourceExtension = "plist"

@MainActor
public final class AddonRegistry {

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "AddonRegistry")

    public init() {}

    /// Snapshot of what is currently installed. Call on app launch and whenever
    /// the user returns to the landing page after having been in the background
    /// (a fresh install won't be picked up until this runs).
    public func discoverInstalled() -> [InstalledAddon] {
        #if os(macOS)
        let workspace = NSWorkspace.shared
        let base = officialAddonBundleIDPrefix
        // LaunchServices doesn't expose a prefix query; enumerate by fetching
        // candidate bundle IDs we know about. For v1 of the framework we only
        // look for the one official addon we ship.
        let candidateBundleIDs: [String] = [
            base + "notebook"
        ]

        var results: [InstalledAddon] = []
        for bundleID in candidateBundleIDs {
            guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
                Self.logger.debug("Not installed: \(bundleID, privacy: .public)")
                continue
            }
            switch InstalledAddon.load(fromBundleAt: appURL) {
            case .success(let installed):
                results.append(installed)
            case .failure(let error):
                Self.logger.warning("Could not load manifest for \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return results
        #else
        return []
        #endif
    }

    /// Launch an addon with an activation payload. Returns `true` if the system
    /// successfully handed the URL off; the addon may still refuse to honor it.
    @discardableResult
    public func activate(_ addon: InstalledAddon, context: AddonActivationContext) -> Bool {
        #if os(macOS)
        do {
            let encoded = try context.encodedForURL()
            var components = URLComponents()
            components.scheme = addon.manifest.urlScheme
            components.host = "activate"
            components.queryItems = [URLQueryItem(name: "ctx", value: encoded)]
            guard let url = components.url else { return false }
            return NSWorkspace.shared.open(url)
        } catch {
            Self.logger.error("Activation encoding failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #else
        return false
        #endif
    }
}

/// An installed addon: manifest + on-disk install state.
public struct InstalledAddon: Identifiable, Sendable {
    public var id: String { manifest.addonID }
    public let manifest: AddonManifest
    public let bundleURL: URL

    public init(manifest: AddonManifest, bundleURL: URL) {
        self.manifest = manifest
        self.bundleURL = bundleURL
    }

    public enum LoadError: LocalizedError {
        case missingManifest
        case decodeFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .missingManifest: return "VerbinalAddon.plist not found in bundle."
            case .decodeFailed(let error): return "Manifest decode failed: \(error.localizedDescription)"
            }
        }
    }

    /// Load from an installed app bundle (`.app`). Reads the baked-in
    /// `VerbinalAddon.plist` inside `Contents/Resources/`.
    public static func load(fromBundleAt url: URL) -> Result<InstalledAddon, LoadError> {
        let plistURL = url
            .appendingPathComponent("Contents/Resources/\(verbinalAddonManifestResourceName).\(verbinalAddonManifestResourceExtension)")
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            return .failure(.missingManifest)
        }
        do {
            let data = try Data(contentsOf: plistURL)
            let decoder = PropertyListDecoder()
            let manifest = try decoder.decode(AddonManifest.self, from: data)
            return .success(InstalledAddon(manifest: manifest, bundleURL: url))
        } catch {
            return .failure(.decodeFailed(error))
        }
    }
}
