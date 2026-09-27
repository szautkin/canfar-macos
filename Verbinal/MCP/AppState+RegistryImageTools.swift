// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// The registry-image tools bound to the app's one list of added images
/// and its registry search — the same ones the images card uses.
extension AppState {
    func makeSearchImageRegistryTool() -> SearchImageRegistryTool {
        SearchImageRegistryTool(
            search: { [weak self] query in try await self?.searchRegistry(query) ?? [] },
            mine: { [weak self] in await self?.userImages.images ?? [] })
    }

    func makeListMyImagesTool() -> ListMyImagesTool {
        ListMyImagesTool(mine: { [weak self] in await self?.userImages.images ?? [] })
    }

    func makeRemoveRegistryImageTool() -> RemoveRegistryImageTool {
        RemoveRegistryImageTool(isListed: { [weak self] id in await self?.userImages.contains(id) ?? false })
    }
}
