// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Payload passed from the host to an addon via URL-scheme activation.
///
/// Encoded as JSON, base64-URL-encoded, appended to the addon's activation URL:
/// `verbinal-pi://activate?ctx=<base64-json>`
///
/// The addon decodes the payload in its `AppDelegate.application(_:open:)` and
/// yields it onto `AddonBeacon.activations`. The root SwiftUI view `.task`-drains
/// the stream and dispatches the appropriate action (open file, center on sky
/// coordinate, etc.).
public enum AddonActivationContext: Codable, Sendable, Equatable {

    /// User tapped the tile with no further context.
    case launchEmpty

    /// Open a file the host picked via `NSOpenPanel`. The URL is a
    /// security-scoped bookmark serialized into the activation payload; the
    /// addon must call `startAccessingSecurityScopedResource()` on it.
    case openFile(url: URL)

    /// Center the addon on a sky coordinate (for notebook-with-target-preset,
    /// FITS viewer follow-up, etc.). Optional file URL can accompany, e.g.
    /// "center on these coords in THIS FITS image".
    case openSkyCoordinate(ra: Double, dec: Double, radius: Double?, fileURL: URL?)

    /// Escape hatch for addon-specific needs the schema does not yet cover.
    case custom(payload: [String: String])
}

public extension AddonActivationContext {

    /// Base64-URL-safe encoding of the JSON payload. Suitable to drop directly
    /// into the `ctx` query parameter.
    func encodedForURL() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return data.base64URLEncodedString()
    }

    /// Decode from the `ctx` query parameter received by the addon.
    static func decode(from base64URL: String) throws -> AddonActivationContext {
        guard let data = Data(base64URLEncoded: base64URL) else {
            throw AddonActivationError.invalidPayload
        }
        return try JSONDecoder().decode(AddonActivationContext.self, from: data)
    }
}

public enum AddonActivationError: LocalizedError {
    case invalidPayload
    case missingContext

    public var errorDescription: String? {
        switch self {
        case .invalidPayload: return "Could not decode addon activation payload."
        case .missingContext: return "Addon activation URL did not include a context."
        }
    }
}

// MARK: - Base64 URL encoding helpers

private extension Data {
    func base64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded input: String) {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
