// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// Multi-document host for spectral cubes, matching the FITS tab host's
/// ownership pattern while keeping each cube's rendering state independent.
@Observable @MainActor
final class CubeTabHostModel {
    var tabs: [CubeViewerModel] = [CubeViewerModel()]
    var activeTabIndex = 0

    var activeTab: CubeViewerModel {
        tabs[min(max(activeTabIndex, 0), tabs.count - 1)]
    }

    /// Opens `url` in a new tab. The UI keeps a failed tab so its error
    /// stays visible; agent callers use `openFileDiscardingFailure(url:)`.
    @discardableResult
    func openFile(url: URL) async -> CubeViewerModel {
        let model = CubeViewerModel()
        tabs.append(model)
        activeTabIndex = tabs.count - 1
        await model.open(url: url)
        return model
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index), tabs.count > 1 else { return }
        tabs.remove(at: index)
        activeTabIndex = min(activeTabIndex, tabs.count - 1)
    }
}

extension CubeTabHostModel: ViewerTabHosting {}

extension CubeViewerModel: ViewerDocument {
    static var documentKind: String { "cube" }
    var isLoaded: Bool { hasData }
}
