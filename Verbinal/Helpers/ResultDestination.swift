// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os
import VerbinalKit

/// Where the results the app keeps go (plan 36 4.1): to the Mac first, the
/// download folder the person chose. When they also keep their results in
/// their CANFAR storage (Settings ▸ Storage ▸ Results), each goes there
/// too, in `Verbinal-Results/<area>/`: sent in the background by the
/// storage sync, and kept to send while storage cannot be reached. Every
/// writer of a result says so here once its file is on the Mac; a test
/// holds them to it.
@Observable
@MainActor
final class ResultDestination {
    enum Area: String, Codable, Sendable {
        /// Research's downloads and cutouts.
        case research
        /// Search results exported.
        case searches
        /// Figures exported from the viewers.
        case figures
    }

    /// A result to send: where it is on the Mac, and the folder it goes to.
    struct Waiting: Codable, Equatable, Sendable {
        let path: String
        let folder: String
    }

    nonisolated static let folder = "Verbinal-Results"

    /// A test host keeps its own, in memory.
    static let shared = ResultDestination(persistence: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                                          ? productionPersistence : nil)

    /// Whether the person keeps their results in storage: set from the manifest.
    var keeping = false
    /// Sends a file to a folder of the person's storage, answering where it
    /// went; set while signed in.
    var send: (@Sendable (_ file: URL, _ folder: String) async throws -> String)?
    /// Told where each result went: Research records it (plan 36 5.1).
    var sent: ((_ file: URL, _ storagePath: String) -> Void)?
    private(set) var waiting: [Waiting] = []
    private let persistence: DiskPersistence<[Waiting]>?

    init(persistence: DiskPersistence<[Waiting]>?) {
        self.persistence = persistence
        if case .value(let stored)? = persistence?.readResult() { waiting = stored }
    }

    nonisolated static let productionPersistence = DiskPersistence<[Waiting]>(
        subdirectory: "Verbinal", fileName: "result_uploads.json",
        logger: Logger(subsystem: "com.codebg.Verbinal", category: "ResultDestination"))

    /// `file`, a result of `area` just kept on the Mac: it goes to storage
    /// too, while the person keeps their results there.
    func kept(_ file: URL, area: Area) {
        guard keeping else { return }
        let entry = Waiting(path: file.path, folder: "\(Self.folder)/\(area.rawValue)")
        guard !waiting.contains(entry) else { return }
        waiting.append(entry)
        save()
    }

    /// Sends what waits, oldest first; answers how many went. One that
    /// cannot go waits for the next sync, and those after it with it; a file
    /// no longer on the Mac is let go.
    func sendWaiting() async -> Int {
        guard keeping, let send else { return 0 }
        stuck = nil
        var sent = 0
        for entry in waiting {
            guard FileManager.default.fileExists(atPath: entry.path) else { letGo(entry); continue }
            do {
                let url = URL(fileURLWithPath: entry.path)
                let path = try await send(url, entry.folder)
                letGo(entry)
                self.sent?(url, path)
                sent += 1
            } catch {
                stuck = error.localizedDescription
                break
            }
        }
        return sent
    }

    /// Why the last results that waited could not go; nil when all went
    /// (plan 44 E4): the sync then fails, saying so, and is tried again.
    private(set) var stuck: String?

    private func letGo(_ entry: Waiting) {
        waiting.removeAll { $0 == entry }
        save()
    }

    private func save() {
        _ = persistence?.write(waiting)
    }
}
