// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
