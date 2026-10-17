// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// What the Portal's cards — Platform Load, Storage, Batch Jobs — share
/// (plan 42): the header, its icon and title, an accessory and the reload
/// button; the card's own body; and one footer line, "Updated …", there
/// from the first moment so the card's height never changes. A reload
/// keeps the body, with the last values, and moves nothing: the button
/// turns into a spinner in its own slot.
struct PortalCardShell<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    /// The card's load: working, loaded when, or why not.
    let phase: Phase<Date>
    let reload: PortalReload
    /// After "Updated …": Batch Jobs' "next in 32 s".
    var next: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                    Spacer(minLength: 4)
                    accessory()
                    PortalReloadButton(working: phase.isWorking, reload: reload)
                }
                content()
                footer
                if phase.problem != nil {
                    ProblemView(problem: phase.problem, retry: { Task { await reload.action() } }, compact: true)
                }
            }
        }
    }

    /// "Updated 16:04:05 · next in 32 s"; before the first load "Loading…",
    /// or a dash: a line there from the first moment.
    private var footer: some View {
        Text(verbatim: footerText)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private var footerText: String {
        guard let updated = phase.value else {
            return next ?? (phase.isWorking ? String(localized: "Loading…") : "—")
        }
        let time = updated.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        let line = String(localized: "Updated \(time)")
        return next.map { "\(line) · \($0)" } ?? line
    }
}

extension PortalCardShell where Accessory == EmptyView {
    init(title: LocalizedStringKey, systemImage: String, phase: Phase<Date>, reload: PortalReload, next: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, phase: phase, reload: reload, next: next,
                  accessory: { EmptyView() }, content: content)
    }
}

extension View {
    /// A card's figures while a reload is under way: still there, dimmed
    /// alike on every card (plan 42).
    func refreshing(_ on: Bool) -> some View {
        opacity(on ? 0.45 : 1)
            .appAnimation(AppMotion.quick, value: on)
    }
}

/// A card's reload: its id, its name ("Refresh storage"), its help, and
/// what it does.
struct PortalReload {
    let id: String
    let name: LocalizedStringKey
    let help: LocalizedStringKey
    let action: @MainActor () async -> Void
}

/// The cards' reload button (plan 42): the arrow, or while it works a small
/// spinner, in one fixed slot — nothing beside it moves. Disabled while it
/// works, and read as "Refreshing" then.
struct PortalReloadButton: View {
    let working: Bool
    let reload: PortalReload

    var body: some View {
        Button {
            Task { await reload.action() }
        } label: {
            Group {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
            }
            .frame(width: Self.slot, height: Self.slot)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .frame(width: Self.slot, height: Self.slot)
        .disabled(working)
        .help(Text(reload.help))
        .accessibilityLabel(Text(reload.name))
        .accessibilityValue(working ? Text("Refreshing") : Text(verbatim: ""))
        .pointable(reload.id)
    }

    /// The slot both the arrow and the spinner fit.
    static let slot: CGFloat = 18
}
