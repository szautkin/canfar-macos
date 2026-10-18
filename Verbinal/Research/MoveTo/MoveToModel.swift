// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// The Move To sheet for the active record (plan 46): its plan, as the
/// person or an assistant sets it, and the moves its button makes, file by
/// file, each a task on the activity bar. Kept on `ResearchModel`, so the
/// tools open and read it as the person sees it.
@MainActor
@Observable
final class MoveToModel: Identifiable {
    /// How a file's move went, while the button's run is under way.
    enum Moving: Equatable { case moving, moved }

    let id = UUID()
    let recordID: UUID
    /// The record as the person knows it: "Cutout of 745234p.fits.fz · D2".
    let title: String
    var plan: MoveToPlan
    private(set) var moving: [String: Moving] = [:]
    private(set) var running = false
    /// Keeping one copy removes the other: asked once more.
    var confirmingRemoval = false

    @ObservationIgnored private let transfer: ResearchFileTransfer
    @ObservationIgnored private let store: ObservationStore
    /// The record after a move, for the screen that shows it.
    @ObservationIgnored var onChange: ((DownloadedObservation) -> Void)?

    init(record: DownloadedObservation, transfer: ResearchFileTransfer, store: ObservationStore,
         to: MoveToPlan.Place? = nil, keepCopy: Bool = true) {
        recordID = record.id
        title = Self.title(of: record)
        self.transfer = transfer
        self.store = store
        plan = MoveToPlan(files: MoveToPlan.files(of: record), signedIn: transfer.storage != nil, to: to, keepCopy: keepCopy)
    }

    static func title(of record: DownloadedObservation) -> String {
        let what = record.cutout.map { String(localized: "Cutout of \(($0.artifactID as NSString).lastPathComponent)") }
            ?? [record.collection, record.observationID].filter { !$0.isEmpty }.joined(separator: " ")
        return [what, record.targetName].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Storage's free space, when it can be told.
    func load(free: (@Sendable () async -> Int64?)?) async {
        guard let free else { return }
        plan.free = await free()
    }

    /// The record's files as they are now, the person's choices kept.
    func refresh() {
        guard let record = store.observation(id: recordID) else { return }
        plan = MoveToPlan(files: MoveToPlan.files(of: record), signedIn: transfer.storage != nil, to: plan.to,
                          keepCopy: plan.keepCopy, unchecked: plan.unchecked, free: plan.free, refused: plan.refused,
                          keepOnly: plan.isKeepOnly)
    }

    /// Makes the moves, file by file. True when every one went: the sheet
    /// closes. A refusal stops it, kept under its file, and the sheet stays.
    @discardableResult
    func run() async -> Bool {
        guard plan.canRun, !running else { return false }
        running = true
        defer { running = false }
        for row in plan.active {
            guard let step = row.step else { continue }
            moving[row.name] = .moving
            do {
                let record = try await perform(step, row.name)
                moving[row.name] = .moved
                onChange?(record)
            } catch {
                moving[row.name] = nil
                plan.refused[row.name] = error.localizedDescription
                refresh()
                return false
            }
        }
        refresh()
        return true
    }

    private func perform(_ step: MoveToPlan.Step, _ name: String) async throws -> DownloadedObservation {
        switch step {
        case .copy(to: .storage): try await transfer.send(name, of: recordID)
        case .copy(to: .mac): try await transfer.fetch(name, of: recordID)
        case .move(let to): try await transfer.move(name, of: recordID, to: to == .storage ? .storage : .mac)
        case .remove(from: .mac): try await transfer.removeFromMac(name, of: recordID)
        case .remove(from: .storage): try await transfer.removeFromStorage(name, of: recordID)
        }
    }
}
