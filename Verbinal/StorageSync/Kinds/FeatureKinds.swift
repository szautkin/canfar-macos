// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// The package lists of CANFAR images, written by Image Discovery's probe
/// jobs (plan 34 V): one this device's cache does not have, or has older,
/// is imported — whichever Mac, or Verbinal for Windows or Linux, probed
/// the image.
struct ImagePackagesKind: StorageKind {
    let id = "imagePackages"
    let defaultFolder = ".verbinal/manifests"
    /// Imports a package list; true when the cache took it.
    let importManifest: @Sendable (Data) async -> Bool

    func sync(_ context: StorageKindContext) async throws -> StorageKindOutcome {
        let lists = context.changed.filter { $0.name.hasSuffix(".json") }
        var imported = 0, done = 0
        if !lists.isEmpty { await context.progress(0, lists.count) }
        for item in lists {
            guard !Task.isCancelled else { break }
            guard let data = try? await context.remote.read("\(context.folder)/\(item.name)") else { continue }
            if await importManifest(data) { imported += 1 }
            done += 1
            // Kept at once: a pause or a quit goes on from the next list.
            await context.took(item)
            await context.progress(done, lists.count)
        }
        return StorageKindOutcome(imported: imported)
    }
}

/// Remote Compute's runs (plan 34 V): a result that came while Verbinal was
/// not watching is handed to its run — by Remote Compute, which knows its
/// runs.
struct ComputeRunsKind: StorageKind {
    let id = "computeRuns"
    let defaultFolder = ".verbinal/exec"
    let itemsSubfolder: String? = "out"
    /// Remote Compute reads the results its runs are waiting for.
    let resume: @Sendable () async -> Void

    func sync(_ context: StorageKindContext) async throws -> StorageKindOutcome {
        guard !context.changed.isEmpty else { return StorageKindOutcome() }
        await resume()
        return StorageKindOutcome(imported: context.changed.count)
    }
}

/// The results the person keeps in their storage too (plan 36 4.1): a sync
/// sends those waiting to go. Another device's are there to browse, never
/// fetched.
struct ResultsKind: StorageKind {
    let id = "results"
    let defaultFolder = ResultDestination.folder
    /// Waits for the person: their allocation.
    let declaredWhenFound = false
    /// Sends what waits; how many went.
    let send: @Sendable () async -> Int
    /// Why what waits could not go, when it could not (plan 44 E4).
    var stuck: @Sendable () async -> String? = { nil }

    func sync(_ context: StorageKindContext) async throws -> StorageKindOutcome {
        let sent = await send()
        // What could not go fails the sync: on the bar, and tried again.
        if let why = await stuck() { throw ResultsWait(why: why, sent: sent) }
        return StorageKindOutcome(sent: sent)
    }

    /// Results that could not go yet, and why.
    struct ResultsWait: LocalizedError {
        let why: String
        let sent: Int
        var errorDescription: String? {
            sent > 0 ? String(localized: "\(sent) results went to your storage; the rest wait: \(why)")
                     : String(localized: "Results wait to go to your storage: \(why)")
        }
    }
}

/// Files Verbinal leaves in VOSpace for the person — batch-job scripts,
/// uploaded exports (plan 34 V): counted, with their size, never deleted.
struct CountedKind: StorageKind {
    let id: String
    let defaultFolder: String

    static let stagedScripts = CountedKind(id: "stagedScripts", defaultFolder: ".verbinal-scripts")
    static let exports = CountedKind(id: "exports", defaultFolder: "Verbinal-Exports")

    func sync(_ context: StorageKindContext) async throws -> StorageKindOutcome {
        StorageKindOutcome()
    }
}
