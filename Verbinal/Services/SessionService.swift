// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

final class SessionService: Sendable {
    private let network: NetworkClient
    private let endpoints: APIEndpoints

    init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints()) {
        self.network = network
        self.endpoints = endpoints
    }

    /// Fetches all sessions, returning normalized Session models.
    func getSessions() async throws -> [Session] {
        let responses = try await network.getJSON(
            endpoints.sessionsURL,
            type: [SkahaSessionResponse].self
        )
        return responses.map { Session(from: $0) }
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
            headers: headers
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
        _ = try await network.delete(endpoints.sessionURL(id))
    }

    /// Renews/extends a session by ID.
    func renewSession(id: String) async throws {
        _ = try await network.post(endpoints.sessionRenewURL(id), formData: [:])
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
