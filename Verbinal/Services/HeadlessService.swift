// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

final class HeadlessService: Sendable {
    private let network: NetworkClient
    private let endpoints: APIEndpoints

    init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints()) {
        self.network = network
        self.endpoints = endpoints
    }

    /// Fetches only headless sessions, filtering client-side.
    func getHeadlessJobs() async throws -> [HeadlessJob] {
        let responses = try await network.getJSON(
            endpoints.sessionsURL,
            type: [SkahaHeadlessResponse].self
        )
        return responses
            .filter { $0.type.lowercased() == "headless" }
            .map { HeadlessJob(from: $0) }
    }

    /// Fetches container logs for a headless job.
    func getLogs(id: String) async throws -> String {
        try await network.getText(endpoints.sessionLogsURL(id))
    }

    /// Fetches Kubernetes events for a headless job.
    func getEvents(id: String) async throws -> String {
        try await network.getText(endpoints.sessionEventsURL(id))
    }

    /// Deletes a headless job by ID.
    func deleteJob(id: String) async throws {
        _ = try await network.delete(endpoints.sessionURL(id))
    }
}
