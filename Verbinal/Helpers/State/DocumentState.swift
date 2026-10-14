// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A viewer tab's document (plan 38) — the FITS image's and the cube's
/// alike: nothing open, opening (how far it has got), failed (why), or
/// open. One value, so a tab is never loading and failed at once, and
/// never shows its controls beside nothing. The file is the tab's own
/// `fileURL`; what an open document shows (an image, a table) is its data.
enum DocumentState: Equatable, Sendable {
    case empty
    /// `stage` as the person reads it ("Reading the header"); `progress`
    /// from 0 to 1 when it is known.
    case opening(stage: String, progress: Double?)
    case failed(Problem)
    case open

    var isOpening: Bool { if case .opening = self { true } else { false } }
    var isOpen: Bool { self == .open }
    var problem: Problem? { if case .failed(let problem) = self { problem } else { nil } }

    /// Its state as an assistant reads it.
    var stateName: String {
        switch self {
        case .empty: "empty"
        case .opening: "opening"
        case .failed: "failed"
        case .open: "open"
        }
    }
}

/// How a viewer tab's document moves (plan 38): any state may begin an
/// open or close; only an open under way takes a stage, opens or fails;
/// an open document can fail too — an extension that will not read.
enum DocumentMachine: StateMachine {
    enum Event: Sendable {
        case begin
        case stage(String, progress: Double? = nil)
        case opened
        case failed(Problem)
        case close
    }

    static func next(_ state: DocumentState, on event: Event) -> DocumentState? {
        switch (state, event) {
        case (_, .begin): .opening(stage: "", progress: nil)
        case (.opening, .stage(let stage, let progress)): .opening(stage: stage, progress: progress)
        case (.opening, .opened): .open
        case (.opening, .failed(let problem)), (.open, .failed(let problem)): .failed(problem)
        case (_, .close): .empty
        default: nil
        }
    }
}

/// An assistant's answer that carries a viewer tab's document state
/// (plan 38): `state`, and `problem` when it failed — the same fields in
/// every viewer's answer.
protocol DocumentStateReporting {
    var state: String? { get set }
    var problem: String? { get set }
}

extension DocumentStateReporting {
    /// The same answer, saying `document`'s state.
    func with(_ document: DocumentState) -> Self {
        var answer = self
        answer.state = document.stateName
        answer.problem = document.problem?.message
        return answer
    }
}
