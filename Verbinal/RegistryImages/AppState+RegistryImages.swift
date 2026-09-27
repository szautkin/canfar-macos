// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

extension AppState {
    /// The images a launch can start: the platform's catalogue, then the
    /// ones the person added that it does not list.
    func catalogueImages() async throws -> [RawImage] {
        userImages.merged(into: try await imageService.getImages())
    }

    /// Search the registry of Settings ▸ Image Discovery with its
    /// credentials — someone who configured discovery is not asked again.
    func searchRegistry(_ query: String) async throws(RegistrySearchError) -> [RegistryImage] {
        let settings = imageDiscoverySettings
        return try await RegistrySearch().search(
            host: settings.settings.registryHost, query: query, basic: settings.currentAuthHeader())
    }
}
