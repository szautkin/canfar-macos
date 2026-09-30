// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Decodes an element or silently returns nil on failure,
/// allowing the rest of the array to decode successfully.
private struct SafeDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Abstraction over the session-launch call so view models that depend on it
/// can be unit-tested with a stub (SessionService is `final`, so it can't be
/// subclassed). SessionService is the production conformer.
protocol SessionLaunching: Sendable {
    func launchSession(_ params: SessionLaunchParams) async throws -> String?
}

final class SessionService: SessionLaunching {
    private let network: NetworkClient
    private let endpoints: APIEndpoints
    /// Where each change to the person's sessions is recorded — here, where
    /// every launch, delete and renewal is made, whoever asks (plan 23 C).
    private let changes: ChangeLog

    init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints(), changes: ChangeLog = .shared) {
        self.network = network
        self.endpoints = endpoints
        self.changes = changes
    }

    /// Excluded session types — these are handled by their own dedicated modules.
    private static let excludedTypes: Set<String> = ["headless", "desktop-app"]

    /// Fetches interactive sessions only, excluding headless/desktop-app entries.
    func getSessions() async throws -> [Session] {
        let (data, _) = try await network.get(endpoints.sessionsURL, accept: "application/json")
        let containers = try JSONDecoder().decode([SafeDecodable<SkahaSessionResponse>].self, from: data)
        return containers
            .compactMap(\.value)
            .filter { !Self.excludedTypes.contains($0.type.lowercased()) }
            .map { Session(from: $0) }
    }

    /// The id of every session the platform lists, of any type — headless
    /// and desktop-app included — to tell a session from a typo (QA N20).
    func allSessionIDs() async throws -> Set<String> {
        struct Listed: Decodable { let id: String }
        let (data, _) = try await network.get(endpoints.sessionsURL, accept: "application/json")
        let listed = try JSONDecoder().decode([SafeDecodable<Listed>].self, from: data)
        return Set(listed.compactMap(\.value?.id))
    }

    private static let defaultRegistry = "images.canfar.net"

    /// Launches a new session. Returns the session ID on success.
    func launchSession(_ params: SessionLaunchParams) async throws -> String? {
        // Ensure image has the registry prefix (API requires it)
        var image = params.image
        let firstComponent = image.split(separator: "/").first.map(String.init) ?? ""
        if !firstComponent.contains(".") {
            image = "\(Self.defaultRegistry)/\(image)"
        }
        return try await changes.run("launch_session", "\(params.type) session \(params.name) (\(image))") {
            try await post(params, image: image)
        }
    }

    private func post(_ params: SessionLaunchParams, image: String) async throws -> String? {

        var formData: [String: String] = [
            "name": params.name,
            "image": image,
            "type": params.type
        ]

        // Fixed: send resourceType=custom + cores/ram/gpus
        // Flexible: send resourceType=shared only (server uses defaults)
        if params.cores > 0 {
            formData["resourceType"] = "custom"
            formData["cores"] = String(params.cores)
            formData["ram"] = String(params.ram)
            if params.gpus > 0 { formData["gpus"] = String(params.gpus) }
        } else {
            formData["resourceType"] = "shared"
        }
        if let cmd = params.cmd, !cmd.isEmpty { formData["cmd"] = cmd }

        // Build custom headers for registry auth
        var headers: [String: String]?
        if let regUser = params.registryUsername,
           let regSecret = params.registrySecret,
           !regUser.isEmpty, !regSecret.isEmpty {
            let credentials = "\(regUser):\(regSecret)"
            if let data = credentials.data(using: .utf8) {
                let encoded = data.base64EncodedString()
                headers = ["x-skaha-registry-auth": encoded]
            }
        }

        let (data, _) = try await network.post(
            endpoints.sessionsURL,
            formData: formData,
            headers: headers,
            timeout: RequestTimeout.launch
        )

        // Response can be JSON array ["sessionId"] or plain text
        let responseText = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if responseText.hasPrefix("[") {
            // JSON array
            if let ids = try? JSONDecoder().decode([String].self, from: data), let first = ids.first {
                return first
            }
        }

        return responseText.isEmpty ? nil : responseText
    }

    /// Deletes a session by ID.
    func deleteSession(id: String) async throws {
        try await changes.run("delete_session", "session \(id)") {
            _ = try await network.delete(endpoints.sessionURL(id))
        }
    }

    /// Renews/extends a session by ID.
    func renewSession(id: String) async throws {
        try await changes.run("renew_session", "session \(id)") {
            _ = try await network.post(endpoints.sessionRenewURL(id), formData: [:])
        }
    }

    /// Fetches Kubernetes events for a session.
    func getSessionEvents(id: String) async throws -> String {
        try await network.getText(endpoints.sessionEventsURL(id))
    }

    /// Fetches container logs for a session.
    func getSessionLogs(id: String) async throws -> String {
        try await network.getText(endpoints.sessionLogsURL(id))
    }

    /// Fetches platform stats.
    func getStats() async throws -> SkahaStatsResponse {
        try await network.getJSON(endpoints.statsURL, type: SkahaStatsResponse.self)
    }
}
