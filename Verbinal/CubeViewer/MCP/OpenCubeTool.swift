// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `open_cube`: the downloaded-observation opener, for the Cube Viewer.
extension OpenDownloadedObservationTool {
    static func cube(open: @escaping @Sendable (_ id: String) async throws -> Opened) -> Self {
        Self(definition: definition(
            name: "open_cube",
            description: "Open a downloaded observation as a 3D spectral cube in the in-app Cube Viewer AND navigate the user's window to the Cube Viewer mode. Answers once the cube is loaded; a very large cube still loading after ~40 s answers `stillLoading: true` instead — do not open it again. Opening a cube that is already open switches to its tab. Live-applied; no proposal. Argument is the downloaded-observation UUID returned by `list_downloaded_observations`. Use this for FITS cubes (NAXIS≥3); for 2D images use `open_fits_file`."),
             open: open)
    }
}
