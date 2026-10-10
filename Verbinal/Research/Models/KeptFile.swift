// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// One of an observation's files, downloaded into Research (plan 34 F):
/// what the archive calls it, and where it is on this computer.
struct KeptFile: Codable, Equatable, Identifiable, Sendable {
    /// The file's name in the archive — `1525350p.fits.fz`: its identity
    /// within the record.
    let name: String
    /// The archive's URI for it, when known: `cadc:CFHT/1525350p.fits.fz`.
    var uri: String? = nil
    /// Where it is: absolute, or as the person knows Downloads.
    var localPath: String
    var bookmarkData: Data?
    var size: Int64?
    var downloadedAt: Date
    /// When an assistant downloaded it.
    var agentAttribution: AgentAttribution? = nil
    /// Where it is in the person's storage too, from their home, once sent
    /// there as a result (plan 36 4.1, 5.1).
    var storagePath: String? = nil
    /// The record's main file, seen as one of its files; never stored.
    var isMain = false

    var id: String { name }
    var local: LocalFile { LocalFile(path: localPath, bookmarkData: bookmarkData) }

    private enum CodingKeys: String, CodingKey {
        case name, uri, localPath, bookmarkData, size, downloadedAt, agentAttribution, storagePath
    }
}
