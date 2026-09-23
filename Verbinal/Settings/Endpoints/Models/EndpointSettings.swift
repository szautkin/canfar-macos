// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// One editable service endpoint. Raw values double as persistence keys
/// and as the `APIEndpoints` field names they map onto.
enum EndpointField: String, CaseIterable, Identifiable, Codable, Sendable {
    case loginBaseURL
    case skahaBaseURL
    case acBaseURL
    case storageBaseURL
    case archiveBaseURL
    case externalBaseURL
    case registryBaseURL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loginBaseURL: return "Login (CADC AC)"
        case .skahaBaseURL: return "Science Platform (Skaha)"
        case .acBaseURL: return "Account (Science Platform AC)"
        case .storageBaseURL: return "Storage (VOSpace nodes)"
        case .archiveBaseURL: return "Archive (TAP / DataLink)"
        case .externalBaseURL: return "External web (browser)"
        case .registryBaseURL: return "IVOA registry (reg)"
        }
    }

    /// Hardcoded CANFAR default — read from `APIEndpoints()` so the
    /// Settings UI can never drift from what the app actually falls
    /// back to.
    var defaultValue: String {
        let defaults = APIEndpoints()
        switch self {
        case .loginBaseURL: return defaults.loginBaseURL
        case .skahaBaseURL: return defaults.skahaBaseURL
        case .acBaseURL: return defaults.acBaseURL
        case .storageBaseURL: return defaults.storageBaseURL
        case .archiveBaseURL: return defaults.archiveBaseURL
        case .externalBaseURL: return defaults.externalBaseURL
        case .registryBaseURL: return defaults.registryBaseURL
        }
    }

    /// The `ivo://` resource ID whose capabilities document locates this
    /// service, when the registry can resolve it. `nil` for endpoints the
    /// registry doesn't describe (browser URLs, the science-platform AC
    /// host, and the registry itself).
    var resourceID: String? {
        switch self {
        case .loginBaseURL: return "ivo://cadc.nrc.ca/gms"
        case .skahaBaseURL: return "ivo://cadc.nrc.ca/skaha"
        case .storageBaseURL: return "ivo://cadc.nrc.ca/arc"
        case .archiveBaseURL: return "ivo://cadc.nrc.ca/argus"
        case .acBaseURL, .externalBaseURL, .registryBaseURL: return nil
        }
    }
}

/// User-entered endpoint overrides. An absent entry means "use the
/// resolved/default value"; values are normalized on write (trimmed,
/// trailing slash dropped) so computed path suffixes concatenate cleanly.
struct EndpointOverrides: Codable, Equatable, Sendable {
    private(set) var values: [EndpointField: String] = [:]

    var isEmpty: Bool { values.isEmpty }

    subscript(field: EndpointField) -> String? { values[field] }

    /// Set (or clear, when nil/blank) an override. Returns true when the
    /// stored value actually changed.
    @discardableResult
    mutating func set(_ value: String?, for field: EndpointField) -> Bool {
        let normalized = value.flatMap(Self.normalize)
        guard values[field] != normalized else { return false }
        values[field] = normalized
        return true
    }

    /// Trim whitespace and drop a trailing "/"; blank collapses to nil.
    static func normalize(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A usable endpoint base: http(s) scheme plus a host.
    static func isValidBase(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}

/// Snapshot of what the IVOA registry said the service locations are.
/// Persisted to disk so later launches start from the last-known-good
/// resolution even when offline.
struct ResolvedEndpoints: Codable, Equatable, Sendable {
    /// Resolved base URLs, keyed by the endpoint field they replace.
    /// Only resolvable fields ever appear here.
    var values: [EndpointField: String] = [:]
    /// Raw per-resource service roots, for the Settings status UI.
    var perService: [String: String] = [:]
    /// Non-fatal oddities found during resolution (e.g. archive services
    /// disagreeing on a common host root). Shown in the Settings tab.
    var warnings: [String] = []
    var fetchedAt: Date
    /// Which registry produced this snapshot — a stale cache from a
    /// different registry must not silently apply after the user points
    /// the app elsewhere.
    var registryBaseURL: String
}

/// Where an endpoint's effective value came from.
enum EndpointSource: String, Sendable {
    case override
    case resolved
    case defaultValue
}

/// Pure precedence engine: user override > cached registry resolution >
/// hardcoded CANFAR default, decided per field.
enum EndpointResolution {

    static func effectiveValue(
        for field: EndpointField,
        overrides: EndpointOverrides,
        resolved: ResolvedEndpoints?
    ) -> String {
        if let value = overrides[field] { return value }
        if let value = resolved?.values[field] { return value }
        return field.defaultValue
    }

    static func source(
        for field: EndpointField,
        overrides: EndpointOverrides,
        resolved: ResolvedEndpoints?
    ) -> EndpointSource {
        if overrides[field] != nil { return .override }
        if resolved?.values[field] != nil { return .resolved }
        return .defaultValue
    }

    static func effective(
        overrides: EndpointOverrides,
        resolved: ResolvedEndpoints?
    ) -> APIEndpoints {
        func value(_ field: EndpointField) -> String {
            effectiveValue(for: field, overrides: overrides, resolved: resolved)
        }
        return APIEndpoints(
            loginBaseURL: value(.loginBaseURL),
            skahaBaseURL: value(.skahaBaseURL),
            acBaseURL: value(.acBaseURL),
            storageBaseURL: value(.storageBaseURL),
            registryBaseURL: value(.registryBaseURL),
            archiveBaseURL: value(.archiveBaseURL),
            externalBaseURL: value(.externalBaseURL)
        )
    }
}
