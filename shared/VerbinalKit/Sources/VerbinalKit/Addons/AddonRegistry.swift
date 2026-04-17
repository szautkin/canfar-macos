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
@MainActor
public final class AddonRegistry {

    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "AddonRegistry")

    /// Known first-party addon bundle IDs. LaunchServices cannot do a
    /// bundle-ID-prefix query on macOS, so we maintain this list explicitly.
    /// Append a line per new official addon as they ship. Nonisolated so the
    /// nonisolated `InstalledAddon.load` can reach it without a main hop.
    internal nonisolated static let officialCandidateBundleIDs: [String] = [
        "com.codebg.Verbinal.addon.notebook"
    ]

    public init() {}

    /// Snapshot of what is currently installed. Call on app launch and whenever
    /// the user returns to the landing page after having been in the background
    /// (a fresh install won't be picked up until this runs).
    public func discoverInstalled() -> [InstalledAddon] {
        #if os(macOS)
        let workspace = NSWorkspace.shared
        // LaunchServices doesn't expose a prefix query on macOS; enumerate
        // the candidate list maintained in `officialCandidateBundleIDs`.
        var results: [InstalledAddon] = []
        for bundleID in Self.officialCandidateBundleIDs {
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

    /// Filename of the manifest baked into every addon's Contents/Resources.
    internal static let manifestResourceName = "VerbinalAddon"
    internal static let manifestResourceExtension = "plist"

    public init(manifest: AddonManifest, bundleURL: URL) {
        self.manifest = manifest
        self.bundleURL = bundleURL
    }

    public enum LoadError: LocalizedError {
        case missingManifest
        case decodeFailed(Error)
        case schemaTooNew(got: Int, supported: Int)

        public var errorDescription: String? {
            switch self {
            case .missingManifest:
                return "VerbinalAddon.plist not found in bundle."
            case .decodeFailed(let error):
                return "Manifest decode failed: \(error.localizedDescription)"
            case .schemaTooNew(let got, let supported):
                return "Addon manifest schema version \(got) is newer than the \(supported) this Verbinal understands. Update Verbinal."
            }
        }
    }

    /// Load from an installed app bundle (`.app`). Reads the baked-in
    /// `VerbinalAddon.plist` inside `Contents/Resources/`.
    ///
    /// Gates on `schemaVersion` — a manifest with a newer schema than the host
    /// understands is rejected so future addons cannot cause silent misread of
    /// unknown fields.
    public static func load(fromBundleAt url: URL) -> Result<InstalledAddon, LoadError> {
        let plistURL = url
            .appendingPathComponent("Contents/Resources/\(manifestResourceName).\(manifestResourceExtension)")
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            return .failure(.missingManifest)
        }
        do {
            let data = try Data(contentsOf: plistURL)
            let decoder = PropertyListDecoder()
            let manifest = try decoder.decode(AddonManifest.self, from: data)
            if manifest.schemaVersion > AddonManifest.currentSchemaVersion {
                return .failure(.schemaTooNew(
                    got: manifest.schemaVersion,
                    supported: AddonManifest.currentSchemaVersion
                ))
            }
            return .success(InstalledAddon(manifest: manifest, bundleURL: url))
        } catch {
            return .failure(.decodeFailed(error))
        }
    }
}
