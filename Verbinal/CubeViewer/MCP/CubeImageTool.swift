// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// `get_cube_image`: the viewer picture tool, for the Cube Viewer.
extension ViewerImageTool {
    static func cube(picture: @escaping @Sendable (Int) async throws -> ViewerPicture) -> Self {
        Self(definition: AIToolDefinition.withStaticSchema(
            name: "get_cube_image",
            description: "See what the Cube Viewer shows: a picture of the whole slice (scaled to `maxPixels`, its pixels kept square and sharp) or the volume, on the viewer's own background, with its marks and, when a pixel has been probed, the spectrum under it — and a caption giving the file, channel, view mode, colormap, background and marks. Capped to stay under the client's response limit.",
            schema: ViewerImageArgs.schema), picture: picture)
    }
}
