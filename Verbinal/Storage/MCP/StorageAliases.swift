// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Storage's tools under the names Verbinal for Windows gives them.
enum StorageAliases {
    static func downloadFromVOSpace(_ inner: DownloadFromVOSpaceTool) -> AliasedToolBox<DownloadFromVOSpaceTool> {
        AliasedToolBox(name: "download_from_vospace", description: "Alias of `download_vospace_file`.", inner: inner)
    }

    static func vospaceMkdir(_ inner: VOSpaceMkdirTool) -> AliasedToolBox<VOSpaceMkdirTool> {
        AliasedToolBox(name: "vospace_mkdir", description: "Alias of `create_vospace_folder`.", inner: inner)
    }
}
