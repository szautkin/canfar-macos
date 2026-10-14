// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// One look for every load (plan 38), over `DataStateContainer`: a spinner
/// until there is something, the content — kept through a refresh, with
/// the problem above it when a later try failed — an empty state, or the
/// problem with Try Again.
struct PhaseView<Value, Content: View, Empty: View>: View {
    let phase: Phase<Value>
    var isEmpty: (Value) -> Bool = { _ in false }
    /// Try Again; nil when there is nothing to try.
    var retry: (() -> Void)?
    @ViewBuilder var empty: () -> Empty
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        DataStateContainer(state: phase.dataState(isEmpty: isEmpty)) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } empty: {
            empty()
        } error: {
            ProblemView(problem: phase.problem, retry: retry)
        } content: {
            if let value = phase.value {
                VStack(spacing: 0) {
                    if let problem = phase.problem {
                        ProblemView(problem: problem, retry: retry, compact: true)
                    }
                    content(value)
                }
            }
        }
    }
}

/// What went wrong, as the person reads it, with Try Again when trying
/// again can help (plan 38) — the same on every screen.
struct ProblemView: View {
    let problem: Problem?
    var retry: (() -> Void)?
    /// A line above content kept from before, not the whole space.
    var compact = false

    var body: some View {
        if let problem, compact {
            // A line, in the house style of an error beside content.
            InlineErrorLabel(message: problem.message, retry: problem.retry ? retry : nil)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let problem {
            // The whole space: nothing loaded to show beside it.
            VStack(spacing: 8) {
                Label(problem.message, systemImage: Self.symbol(problem.kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry, problem.retry {
                    Button("Try Again", action: retry)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func symbol(_ kind: Problem.Kind) -> String {
        switch kind {
        case .signInRequired: "person.crop.circle.badge.exclamationmark"
        case .notFound: "questionmark.circle"
        case .offline: "wifi.exclamationmark"
        case .refused: "lock"
        case .cancelled: "stop.circle"
        case .other: "exclamationmark.triangle"
        }
    }
}
