// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// One spelling per file: `.`, `..` and symlinks resolved. What decides
/// that two paths are the same file — for "already open" tabs and for the
/// marks kept with a file (Windows lost marks to another spelling of the
/// same path).
enum FileIdentity {
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
