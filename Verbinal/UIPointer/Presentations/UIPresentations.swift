// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// What a presentation is.
enum UIPresentationKind: String, Codable, Sendable {
    case sheet, popover, confirmation, alert
    /// A system Open or Save panel.
    case filePanel
}

/// What is shown over the screen — every sheet, popover, confirmation and
/// alert, while it is shown — so an assistant can see it and close it, and
/// what can be opened by its name (plan 30 T). The person's decision:
/// "MCP should be able to open and close any modal, screen, dropdown —
/// anything in the app".
@MainActor
final class UIPresentations {
    static let shared = UIPresentations()

    struct Shown: Identifiable, Sendable {
        let id: UUID
        let name: String
        let kind: UIPresentationKind
    }

    /// A presentation that needs nothing chosen first, opened by its name.
    struct Openable: Sendable {
        let name: String
        /// The screen it opens on (`navigate_to`'s mode); nil for anywhere.
        let screen: String?
        let open: @MainActor @Sendable () -> Void
    }

    /// What is shown, in the order it opened: the last is in front.
    private(set) var shown: [Shown] = []
    private var dismissals: [UUID: @MainActor () -> Void] = [:]
    private(set) var openable: [Openable] = []

    func begin(_ name: String, _ kind: UIPresentationKind, dismiss: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        shown.append(Shown(id: id, name: name, kind: kind))
        dismissals[id] = dismiss
        return id
    }

    func end(_ id: UUID) {
        shown.removeAll { $0.id == id }
        dismissals[id] = nil
    }

    /// The shown one a name means — by its name, in any case, or what it
    /// begins with — the front one first; "front" is the front one.
    func shown(named name: String) -> Shown? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        if wanted == "front" { return shown.last }
        return shown.last { $0.name.lowercased() == wanted }
            ?? shown.last { $0.name.lowercased().hasPrefix(wanted) && !wanted.isEmpty }
    }

    /// Closes it as the person's Esc or Cancel would: its own binding,
    /// cleared. Nothing in it is chosen.
    @discardableResult
    func close(_ shown: Shown) -> Bool {
        guard let dismiss = dismissals[shown.id] else { return false }
        dismiss()
        return true
    }

    func register(openable: Openable) {
        self.openable.removeAll { $0.name == openable.name }
        self.openable.append(openable)
    }

    func openable(named name: String) -> Openable? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return openable.first { $0.name.lowercased() == wanted }
    }
}

private struct PresentedRegistration: ViewModifier {
    let name: String
    let kind: UIPresentationKind
    let isPresented: Binding<Bool>
    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented.wrappedValue, initial: true) { _, shown in update(shown) }
            .onDisappear {
                if let token { UIPresentations.shared.end(token) }
                token = nil
            }
    }

    private func update(_ shown: Bool) {
        if shown, token == nil {
            let binding = isPresented
            token = UIPresentations.shared.begin(name, kind) { binding.wrappedValue = false }
        } else if !shown, let token {
            UIPresentations.shared.end(token)
            self.token = nil
        }
    }
}

extension View {
    /// Says what the presentation just before this is, while it is shown —
    /// a sheet, popover, confirmation or alert — so `list_ui_targets` lists
    /// it and `close_ui` closes it by its name (plan 30 T). Every
    /// presentation in the app has one; a test holds it to that.
    func uiPresented(_ name: String, _ kind: UIPresentationKind, isPresented: Binding<Bool>) -> some View {
        modifier(PresentedRegistration(name: name, kind: kind, isPresented: isPresented))
    }

    /// The same, for one presented by an item.
    func uiPresented<Item>(_ name: String, _ kind: UIPresentationKind, item: Binding<Item?>) -> some View {
        uiPresented(name, kind, isPresented: Binding(get: { item.wrappedValue != nil },
                                                     set: { if !$0 { item.wrappedValue = nil } }))
    }
}

#if os(macOS)
import AppKit

extension UIPresentations {
    /// Runs a system Open or Save panel, known as `name` while it is up:
    /// `list_ui_targets` lists it, and `close_ui` cancels it, as the
    /// person's Cancel does (plan 30 T2). Every panel in the app runs
    /// through this; a test holds it to that.
    ///
    /// For a button's or menu's own action. A panel's modal loop started
    /// inside a task holds every other main-actor job — the tools too —
    /// until the person answers it: async code awaits the other form.
    func runModal(_ panel: NSSavePanel, _ name: String) -> NSApplication.ModalResponse {
        let id = begin(name, .filePanel) { panel.cancel(nil) }
        defer { end(id) }
        return panel.runModal()
    }

    /// The same, from async code: the panel runs from the run loop, so the
    /// tools still answer while it waits for the person.
    func runModal(_ panel: NSSavePanel, _ name: String) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { answered in
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    answered.resume(returning: self.runModal(panel, name))
                }
            }
        }
    }
}
#endif
