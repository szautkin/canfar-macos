// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Move To for assistants (plan 46 M5).
extension AppState {
    func makeMoveToTools() -> [any AITool] {
        [
            GetMoveToViewTool(view: { [weak self] in
                await MainActor.run { self?.moveToView() ?? .closed }
            }),
            ShowMoveToTool(show: { [weak self] args in
                guard let self else { throw ToolFailureReason.backendError("app state gone") }
                return try await MainActor.run { try self.showMoveTo(args) }
            }),
            MoveResearchFilesTool(check: { [weak self] args in
                guard let self else { throw ToolFailureReason.backendError("app state gone") }
                return try await MainActor.run { try self.moveResearchFilesPayload(args) }
            }),
        ]
    }

    func makeMoveResearchFilesApplier(activity: AgentActivityStore) -> MoveResearchFilesApplier {
        MoveResearchFilesApplier(run: { [weak self] payload in
            guard let self else { throw ProposalApplyError.backendError("app state gone") }
            return try await self.applyMoveResearchFiles(payload)
        }, activity: activity)
    }

    /// The sheet as the person sees it.
    func moveToView() -> MoveToView {
        researchModel.moveTo.map(MoveToView.init) ?? .closed
    }

    /// Selects the record, as a click would, and opens Move To on it with
    /// the assistant's choice: the person presses its button.
    func showMoveTo(_ args: MoveToArgs) throws -> MoveToView {
        try requireSignInFor("Storage")
        let record = try moveToRecord(args.id)
        let plan = try moveToPlan(record, args)
        navigateTo(.research)
        researchModel.selectedObservation = record
        let sheet = researchModel.openMoveTo(record, to: plan.to, keepCopy: plan.keepCopy)
        sheet.plan.unchecked = plan.unchecked
        noteLive("show_move_to", "Opened Move To on \(sheet.title): \(sheet.plan.buttonTitle)")
        return MoveToView(sheet)
    }

    /// What move_research_files does, judged when it is asked.
    func moveResearchFilesPayload(_ args: MoveToArgs) throws -> MoveResearchFilesTool.Payload {
        try requireSignInFor("Storage")
        let record = try moveToRecord(args.id)
        let plan = try moveToPlan(record, args)
        guard plan.canRun else {
            let held = plan.rows.compactMap { row in row.held.map { "\(row.name): \(MoveToView.words($0))" } }
            throw ToolFailureReason.invalidArgument(
                (plan.summary + held).joined(separator: " ") + " — get_move_to_view or list_downloaded_observations says where each file is")
        }
        return MoveResearchFilesTool.Payload(
            id: record.id.uuidString, to: plan.to.rawValue, keepCopy: plan.keepCopy, files: plan.active.map(\.name),
            removes: plan.active.compactMap { $0.step?.removes }.first?.rawValue,
            summary: "\(plan.buttonTitle): \(MoveToModel.title(of: record))")
    }

    /// Makes the approved moves, if they still do what they did when asked.
    func applyMoveResearchFiles(_ payload: MoveResearchFilesTool.Payload) async throws -> AutoAppliedAck.Extra {
        try requireSignInFor("Storage")
        let research = researchModel
        guard let id = UUID(uuidString: payload.id), let record = research.observationStore.observation(id: id) else {
            throw ProposalApplyError.backendError("the record \(payload.id) is no longer in Research")
        }
        let sheet = MoveToModel(record: record, transfer: research.transfer, store: research.observationStore,
                                to: MoveToPlan.Place(rawValue: payload.to), keepCopy: payload.keepCopy)
        sheet.plan.unchecked = Set(sheet.plan.files.map(\.name)).subtracting(payload.files)
        guard sheet.plan.active.map(\.name) == payload.files,
              sheet.plan.active.compactMap({ $0.step?.removes }).first?.rawValue == payload.removes else {
            throw ProposalApplyError.backendError("\(sheet.title)'s files are not where they were when this was asked: get_move_to_view, and ask again")
        }
        sheet.onChange = { [weak research] updated in
            if research?.selectedObservation?.id == updated.id { research?.selectedObservation = updated }
        }
        let went = await sheet.run()
        let after = sheet.plan.rows.map { "\($0.name): \($0.now.word)" }.joined(separator: ", ")
        guard went else {
            let refused = sheet.plan.rows.compactMap { row -> String? in
                if case .refused(let why)? = row.held { "\(row.name): \(why)" } else { nil }
            }
            throw ProposalApplyError.backendError((refused + ["now \(after)"]).joined(separator: "; "))
        }
        return AutoAppliedAck.Extra(id: payload.id, note: "places now — \(after)")
    }

    private func moveToRecord(_ raw: String) throws -> DownloadedObservation {
        let store = researchModel.observationStore
        guard let record = store.record(identifiedBy: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let hint = store.likelyID(for: raw).map { " — did you mean \($0.uuidString)?" } ?? ""
            throw ToolFailureReason.invalidArgument("no observation \"\(raw)\" in Research\(hint) — list_downloaded_observations gives the ids")
        }
        guard !record.allFiles.isEmpty else {
            throw ToolFailureReason.invalidArgument("\(MoveToModel.title(of: record)) has no file, on this Mac or in your storage — download_observation fetches it")
        }
        return record
    }

    private func moveToPlan(_ record: DownloadedObservation, _ args: MoveToArgs) throws -> MoveToPlan {
        let to = try args.to.map { raw -> MoveToPlan.Place in
            guard let place = MoveToPlan.Place(rawValue: raw) else { throw ToolFailureReason.invalidArgument("to is storage or mac") }
            return place
        }
        var plan = MoveToPlan(files: MoveToPlan.files(of: record), signedIn: researchModel.transfer.storage != nil,
                              to: to, keepCopy: args.keepCopy ?? true)
        if let files = args.files {
            let names = Set(plan.files.map(\.name))
            let unknown = files.filter { !names.contains($0) }
            guard unknown.isEmpty else {
                throw ToolFailureReason.invalidArgument("\(MoveToModel.title(of: record)) has no file \(unknown.joined(separator: ", ")); its files: \(names.sorted().joined(separator: ", "))")
            }
            plan.unchecked = names.subtracting(files)
        }
        return plan
    }
}
