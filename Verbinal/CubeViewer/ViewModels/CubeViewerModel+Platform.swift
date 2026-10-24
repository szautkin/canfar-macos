// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

extension CubeViewerModel {
    /// The volume texture's longest edge, which the ingest bins the cube to:
    /// 512 on the Mac; 256 on iPhone and iPad, an eighth of the memory, for a
    /// phone's budget (plan 47 5.6).
    static let volumeEdge: Int = {
        #if os(iOS)
        256
        #else
        512
        #endif
    }()
}
