// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import UniformTypeIdentifiers

/// Describes a single addon: what it is, how to reach it, what it claims to do,
/// and whether it needs the host's CADC credentials.
///
/// Every addon declares a manifest. Official addons (same team ID as the host)
/// are discovered by LaunchServices bundle-id scan; community addons drop a JSON
/// copy of their manifest into the shared App Group container on first launch.
public struct AddonManifest: Codable, Sendable, Identifiable {

    /// Protocol-schema version. Bumped when breaking fields are added. The host
    /// ignores manifests it does not understand so old host binaries cannot
    /// crash on a future addon's manifest.
    public static let currentSchemaVersion: Int = 1

    public var id: String { addonID }

    /// `AddonManifest.currentSchemaVersion` at encode time.
    public var schemaVersion: Int

    /// Bundle identifier of the addon app. For official addons this matches the
    /// regex `^com\.codebg\.Verbinal\.addon\..+$`.
    public var addonID: String

    /// Short product name shown under the landing-page tile.
    public var displayName: String

    /// One-line marketing description shown in install popovers and settings.
    public var subtitle: String

    /// SF Symbol name for the landing-page tile. `nil` falls back to a generic
    /// `puzzlepiece.extension` glyph.
    public var systemIconName: String?

    /// URL scheme the addon registers so the host can send activation calls.
    /// `verbinal-pi` in the case of the Pi addon. No trailing `://`.
    public var urlScheme: String

    /// Semver of the addon build.
    public var version: String

    /// Minimum compatible host version. The host refuses to activate an addon
    /// that requires a newer host and surfaces an "update Verbinal" tile.
    public var minimumHostVersion: String

    /// Capabilities the addon advertises. See `AddonCapability`.
    public var capabilities: [AddonCapability]

    /// Whether the addon needs access to the user's CADC credentials.
    public var authRequirement: AddonAuthRequirement

    /// Trust tier. See `AddonTrust`.
    public var trust: AddonTrust

    /// App Store product ID for the "Install from App Store" flow.
    /// `nil` for community addons that distribute via DMG / own channels.
    public var appStoreID: Int?

    public init(
        schemaVersion: Int = AddonManifest.currentSchemaVersion,
        addonID: String,
        displayName: String,
        subtitle: String,
        systemIconName: String? = nil,
        urlScheme: String,
        version: String,
        minimumHostVersion: String,
        capabilities: [AddonCapability],
        authRequirement: AddonAuthRequirement,
        trust: AddonTrust,
        appStoreID: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.addonID = addonID
        self.displayName = displayName
        self.subtitle = subtitle
        self.systemIconName = systemIconName
        self.urlScheme = urlScheme
        self.version = version
        self.minimumHostVersion = minimumHostVersion
        self.capabilities = capabilities
        self.authRequirement = authRequirement
        self.trust = trust
        self.appStoreID = appStoreID
    }
}

/// What an addon claims it can do. Capabilities are advisory — the host uses
/// them to decide which addons to suggest for cross-module actions (e.g. "open
/// this FITS file in a viewer").
public enum AddonCapability: Codable, Sendable, Equatable {
    /// Opens file types declared by UTI. The host prefers a viewer addon when
    /// the user activates a document Finder-side.
    case viewer(fileTypes: [String])
    /// Receives structured data, returns a processed result + provenance.
    case analyzer
    /// Generates new datasets or documents (notebook = producer of .ipynb).
    case producer
    /// Wraps an external file format for export / sharing outside Verbinal.
    case exporter(fileTypes: [String])
    /// Talks to a CADC/remote service. Advertises the service via the `name` field.
    case serviceClient(name: String)
}

/// Does this addon need a CADC token to function?
public enum AddonAuthRequirement: String, Codable, Sendable, Equatable {
    /// Addon never calls CADC. Token is never shared.
    case none
    /// Addon functions without auth but offers more when signed in.
    case cadcOptional
    /// Addon cannot function without the CADC token. Activation will prompt
    /// the user to sign in if they have not already.
    case cadcRequired
}

/// Whether the addon is first-party (team-signed, installed via MAS) or
/// third-party community (any team ID, distributed as a notarized DMG).
public enum AddonTrust: Codable, Sendable, Equatable {
    /// Shipped by the Verbinal team — same signing identity as the host,
    /// shares Keychain + App Group via the team-ID prefix.
    case official(teamID: String, keychainAccessGroup: String)
    /// Community-built — different team ID, no shared resources, auth is
    /// handled via URL-callback handshake (Phase 7 work; not yet active).
    case community(homepageURL: URL?)
}

// MARK: - UTType bridging convenience

public extension AddonCapability {
    /// Returns the file-type identifiers declared by a `viewer`/`exporter`
    /// capability, or an empty array for other cases.
    var declaredFileTypes: [String] {
        switch self {
        case .viewer(let fileTypes), .exporter(let fileTypes):
            return fileTypes
        case .analyzer, .producer, .serviceClient:
            return []
        }
    }
}
