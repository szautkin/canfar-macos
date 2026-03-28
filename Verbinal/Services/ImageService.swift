// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

final class ImageService: Sendable {
    private let network: NetworkClient
    private let endpoints: APIEndpoints

    init(network: NetworkClient, endpoints: APIEndpoints = APIEndpoints()) {
        self.network = network
        self.endpoints = endpoints
    }

    /// Fetches available container images.
    func getImages() async throws -> [RawImage] {
        try await network.getJSON(endpoints.imagesURL, type: [RawImage].self)
    }

    /// Fetches session resource context (CPU/RAM/GPU options).
    func getContext() async throws -> SessionContext {
        try await network.getJSON(endpoints.contextURL, type: SessionContext.self)
    }

    /// Fetches available image repositories/registries.
    func getRepositories() async throws -> [String] {
        try await network.getJSON(endpoints.repositoryURL, type: [String].self)
    }
}
