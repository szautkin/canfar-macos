// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os
import VerbinalKit

/// What a file on this Mac is, by an identity every device shares (plan 36
/// 4.2), so the marks and bookmarks kept with it follow it there:
/// - `vos:<path from home>` — one opened from the person's storage;
/// - `caom:<record key>/<file name>` — one of a Research record;
/// - otherwise its path here, as `FileIdentity` spells it: the Mac's alone.
@MainActor
final class FileOrigins {
    /// A test host keeps its own, in memory.
    static let shared = FileOrigins(persistence: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                                    ? productionPersistence : nil)

    /// Research's own answer for a file of one of its records; set by Research.
    var research: (URL) -> String? = { _ in nil }

    /// Storage's files opened here, by their path on this Mac.
    private var fromStorage: [String: String]
    private let persistence: DiskPersistence<[String: String]>?

    init(persistence: DiskPersistence<[String: String]>? = FileOrigins.productionPersistence) {
        self.persistence = persistence
        if case .value(let stored)? = persistence?.readResult() { fromStorage = stored } else { fromStorage = [:] }
    }

    nonisolated static let productionPersistence = DiskPersistence<[String: String]>(
        subdirectory: "Verbinal", fileName: "file_origins.json",
        logger: Logger(subsystem: "com.codebg.Verbinal", category: "FileOrigins"))

    /// `url` was downloaded from the person's storage, at `path` from their home.
    func noteFromStorage(_ url: URL, path: String) {
        fromStorage[FileIdentity.key(url)] = "vos:" + path
        _ = persistence?.write(fromStorage)
    }

    /// The identity of the file at `url`.
    func identity(of url: URL) -> String {
        research(url) ?? fromStorage[FileIdentity.key(url)] ?? FileIdentity.key(url)
    }

    /// Whether `identity` names the file on every device, not only here.
    nonisolated static func isPortable(_ identity: String) -> Bool {
        identity.hasPrefix("vos:") || identity.hasPrefix("caom:")
    }
}
