// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// The runs on the person's compute session, read back from /arc (plan 47
/// 2.2): every run, from any device or assistant — not only those this
/// device sent. No sync: the watcher's own folders are the record.
@Observable
@MainActor
final class ComputeRunHistory: PhaseOwner {
    /// How many of the newest runs are read.
    static let limit = 25
    /// How many files are read at once.
    private static let parallelReads = 6

    private let files: VOSpaceBrowserService
    private let username: () -> String

    /// /arc's runs, newest first, before this device's are merged in.
    private(set) var arcRuns: [ComputeRunItem] = []
    /// Loading, loaded (when), or why not.
    private(set) var load: Phase<Date> = .idle

    init(files: VOSpaceBrowserService, username: @escaping () -> String) {
        self.files = files
        self.username = username
    }

    /// Reads the three folders, then the newest runs' requests and results.
    func reload() async {
        let user = username()
        guard !user.isEmpty else { return }
        await run(\.load) {
            async let out = folder(RunCodeContract.outDir, user)
            async let done = folder(RunCodeContract.execDir + "/done", user)
            async let inbox = folder(RunCodeContract.inboxDir, user)
            let listings = ComputeRunItems.listings(out: try await out, done: try await done,
                                                    inbox: try await inbox, limit: Self.limit)
            arcRuns = await items(listings, user)
            return Date()
        }
    }

    /// A folder's files; none when the folder is not there yet (no run ever).
    private func folder(_ path: String, _ user: String) async throws -> [ComputeRunItems.ArcFile] {
        do {
            return try await files.listNodes(username: user, path: path)
                .filter { !$0.isContainer }
                .map { ComputeRunItems.ArcFile(name: $0.name, modified: $0.lastModified) }
        } catch NetworkError.httpError(404, _) {
            return []
        }
    }

    /// Each run's request and result, `parallelReads` at a time, in the
    /// listings' order.
    private func items(_ listings: [ComputeRunItems.Listing], _ user: String) async -> [ComputeRunItem] {
        let files = self.files
        var read: [Int: ComputeRunItem] = [:]
        await withTaskGroup(of: (Int, ComputeRunItem).self) { group in
            var next = 0
            func add() {
                guard next < listings.count else { return }
                let index = next, listing = listings[index]
                next += 1
                group.addTask {
                    async let request = Self.read(RunCodeContract.Request.self, files, user,
                                                  listing.hasRequest ? RunCodeContract.execDir + "/done/\(listing.id).json"
                                                    : listing.isWaiting ? RunCodeContract.inboxDir + "/\(listing.id).json" : nil)
                    async let result = Self.read(RunCodeContract.ResultFile.self, files, user,
                                                 listing.hasResult ? RunCodeContract.outDir + "/\(listing.id).json" : nil)
                    return (index, ComputeRunItems.item(listing, request: await request, result: await result))
                }
            }
            for _ in 0..<Self.parallelReads { add() }
            for await (index, item) in group {
                read[index] = item
                add()
            }
        }
        return listings.indices.compactMap { read[$0] }
    }

    /// A JSON file decoded, or nil when it is missing or not whole yet.
    private nonisolated static func read<T: Decodable>(_ type: T.Type, _ files: VOSpaceBrowserService,
                                                       _ user: String, _ path: String?) async -> T? {
        guard let path,
              let data = try? await files.readFile(username: user, path: path, maxBytes: RunCodeContract.maxResultBytes)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
