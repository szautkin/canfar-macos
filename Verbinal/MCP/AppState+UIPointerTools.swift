// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Pointing at the interface: what is on screen, and hints on it (plan 27).
extension AppState {
    func makeListUITargetsTool() -> ListUITargetsTool {
        ListUITargetsTool(snapshot: { [weak self] in
            await self?.uiHintPresenter.ready()
            return await MainActor.run { self?.uiHintPresenter.snapshot() ?? .empty }
        }, hiddenPanels: { [weak self] in
            await MainActor.run {
                UIPanel.allCases.filter { self?.isShown($0) == false }.map { .init(id: $0.id, name: $0.name) }
            }
        })
    }

    func makeShowUIHintsTool() -> ShowUIHintsTool {
        ShowUIHintsTool(show: { [weak self] args in
            await self?.showUIHints(args) ?? .init(message: "App state unavailable")
        })
    }

    func makePointAtUITool() -> PointAtUITool {
        PointAtUITool(show: { [weak self] args in
            await self?.showUIHints(args) ?? .init(message: "App state unavailable")
        })
    }

    func makeSelectUITool() -> SelectUITool {
        SelectUITool(select: { [weak self] args in
            await self?.selectUI(args) ?? .init(selected: false, message: "App state unavailable")
        })
    }

    /// Finds the entry, brings it into view, and selects it as a click does.
    @MainActor
    func selectUI(_ args: SelectUITool.Args) async -> SelectUITool.Output {
        let presenter = uiHintPresenter
        await presenter.ready()
        let snapshot = presenter.snapshot()
        switch UITargetScope.match(args.target, in: snapshot, preferring: Set(UIElementKind.allCases.filter(\.selects))) {
        case .missing(let candidates, _):
            return .init(selected: false, target: args.target,
                         message: snapshot.problem ?? "no single entry is called \"\(args.target)\"",
                         candidates: candidates.map(UITargetView.init))
        case .found(let element):
            guard element.kind.selects else {
                return .init(selected: false, target: args.target, id: element.id,
                             message: "\(element.id) is a \(element.kind.rawValue): select_ui selects a list's entry, a tab or a segment, never presses a button")
            }
            let (now, selected) = await presenter.select(element)
            if selected {
                agentsService.activityStore.append(.live(
                    kind: "select_ui", summary: "Selected \(now.name ?? now.id)", origin: .external(clientID: "select_ui")))
            }
            return .init(selected: selected, target: args.target, id: now.id,
                         message: selected ? nil
                             : "this list's entries do not select — they act through their buttons; point at the button you mean")
        }
    }

    func makeOpenUITool() -> OpenCloseUITool {
        .open { [weak self] args in await self?.setUIOpen(args, open: true) ?? .init(done: false) }
    }

    func makeCloseUITool() -> OpenCloseUITool {
        .close { [weak self] args in await self?.setUIOpen(args, open: false) ?? .init(done: false) }
    }

    /// Opens or closes one closed thing on purpose: a panel by app state, a
    /// section or a menu as a click does it (plan 27 C).
    @MainActor
    func setUIOpen(_ args: OpenCloseUITool.Args, open: Bool) async -> OpenCloseUITool.Output {
        let presenter = uiHintPresenter
        await presenter.ready()
        let before = Set(presenter.snapshot().elements.map(\.id))
        // A sheet, popover, confirmation or alert: closed by its name, or the
        // front one, as Esc would; opened by its name when it needs nothing
        // chosen first (plan 30 T).
        let presentations = UIPresentations.shared
        if !open, let shown = presentations.shown(named: args.target) {
            presentations.close(shown)
            agentsService.activityStore.append(.live(kind: "close_ui", summary: "Closed \(shown.name)",
                                                     origin: .external(clientID: "close_ui")))
            return .init(done: true, target: args.target, id: "presented:\(shown.name)", kind: shown.kind.rawValue)
        }
        if open, let openable = presentations.openable(named: args.target) {
            if presentations.shown(named: openable.name) != nil {
                return .init(done: true, target: args.target, id: "presented:\(openable.name)", kind: "presentation",
                             message: "\(openable.name) was already open")
            }
            if let screen = openable.screen, let mode = AppMode(rawValue: screen), currentMode != mode {
                navigateTo(mode)
                try? await Task.sleep(for: .milliseconds(300))
            }
            openable.open()
            try? await Task.sleep(for: .milliseconds(600))
            let now = presenter.snapshot()
            // Nothing opens in sight where no window shows: the person brings one back.
            if now.problem == UISnapshot.notShowing {
                return .init(done: false, target: args.target, id: "presented:\(openable.name)", kind: "presentation",
                             message: "\(openable.name) is not in sight: no Verbinal window shows here. Ask the person to click Verbinal in the Dock, or to bring its window to this desktop.")
            }
            agentsService.activityStore.append(.live(kind: "open_ui", summary: "Opened \(openable.name)",
                                                     origin: .external(clientID: "open_ui")))
            return .init(done: true, target: args.target, id: "presented:\(openable.name)", kind: "presentation",
                         inside: now.elements.filter { !before.contains($0.id) }.map(UITargetView.init))
        }
        // A right-click menu that is open closes as Esc closes it (plan 30 T2).
        if !open, args.target.trimmingCharacters(in: .whitespaces).lowercased() == "menu", presenter.cancelOpenMenus() {
            return .init(done: true, target: args.target, kind: "menu")
        }
        if let panel = UIPanel.named(args.target) {
            let was = isShown(panel)
            setShown(panel, open)
            var inside: [UIElement] = []
            if open, !was {
                try? await Task.sleep(for: .milliseconds(400))
                inside = presenter.snapshot().elements.filter { !before.contains($0.id) }
            }
            return .init(done: true, target: args.target, id: panel.id, kind: "panel",
                         inside: inside.map(UITargetView.init),
                         message: was == open ? "\(panel.name) was already \(open ? "shown" : "hidden")" : nil)
        }
        // A sheet or popover that needs something chosen first opens from its
        // control: the one control on screen that opens it, by its name.
        let wanted = args.target.trimmingCharacters(in: .whitespaces).lowercased()
        let openers = presenter.lastSnapshot.elements.filter { $0.presents?.lowercased() == wanted }
        if open, openers.count > 1 {
            return .init(done: false, target: args.target,
                         message: "\(openers.count) controls open \(args.target): name the one you mean",
                         candidates: openers.map(UITargetView.init))
        }
        let match = openers.count == 1 && open ? UITargetScope.Match.found(openers[0])
            : UITargetScope.match(args.target, in: presenter.lastSnapshot, preferring: Set(UIElementKind.allCases.filter(\.opens)))
        switch match {
        case .missing(let candidates, _):
            return .init(done: false, target: args.target,
                         message: presenter.lastSnapshot.problem ?? "no single closed section, panel or menu is called \"\(args.target)\"",
                         candidates: candidates.map(UITargetView.init))
        case .found(let element) where element.presents != nil:
            return await openOrClose(element, presenting: element.presents ?? "", open: open, target: args.target)
        case .found(let element):
            guard element.kind.opens else {
                return await rightClickMenu(of: element, open: open, target: args.target)
            }
            guard element.closed == open else {
                return .init(done: true, target: args.target, id: element.id, kind: element.kind.rawValue,
                             message: "\(element.id) was already \(open ? "open" : "closed")")
            }
            var current = element
            if !element.inSight, let moved = await presenter.bringIntoView([element])[element.id] { current = moved }
            let (done, appeared) = await presenter.setOpen(current, open)
            let menu = current.kind != .disclosure
            if done {
                agentsService.activityStore.append(.live(
                    kind: open ? "open_ui" : "close_ui",
                    summary: "\(open ? "Opened" : "Closed") \(current.name ?? current.id)",
                    origin: .external(clientID: open ? "open_ui" : "close_ui")))
            }
            return .init(done: done, target: args.target, id: current.id, kind: current.kind.rawValue,
                         waiting: open && menu && done ? true : nil,
                         inside: appeared.map(UITargetView.init),
                         message: !done ? "\(current.id) did not \(open ? "open" : "close")"
                             : open && menu ? "the menu waits for the person: they choose from it or press Esc" : nil)
        }
    }

    /// Opens what a control opens, pressing it once as the person's click
    /// would — nothing inside is chosen — or closes it, as Esc would (plan
    /// 30 T2). A system file panel stays up for the person.
    @MainActor
    private func openOrClose(_ element: UIElement, presenting name: String, open: Bool,
                             target: String) async -> OpenCloseUITool.Output {
        let presentations = UIPresentations.shared
        let id = "presented:\(name)"
        if let shown = presentations.shown(named: name), shown.name.lowercased() == name.lowercased() {
            guard !open else { return .init(done: true, target: target, id: id, kind: shown.kind.rawValue, message: "\(name) was already open") }
            presentations.close(shown)
            agentsService.activityStore.append(.live(kind: "close_ui", summary: "Closed \(name)", origin: .external(clientID: "close_ui")))
            return .init(done: true, target: target, id: id, kind: shown.kind.rawValue)
        }
        guard open else { return .init(done: true, target: target, id: id, message: "\(name) was already closed") }
        let presenter = uiHintPresenter
        var current = element
        if !element.inSight, let moved = await presenter.bringIntoView([element])[element.id] { current = moved }
        let (pressed, appeared) = await presenter.setOpen(current, true)
        guard pressed, let shown = presentations.shown(named: name) else {
            return .init(done: false, target: target, id: current.id, kind: current.kind.rawValue,
                         message: pressed ? "pressed \(current.id), and \(name) has not shown yet: list_ui_targets' `presented` says when it has"
                             : "\(current.id) could not be pressed")
        }
        agentsService.activityStore.append(.live(kind: "open_ui", summary: "Opened \(name)", origin: .external(clientID: "open_ui")))
        let panel = shown.kind == .filePanel
        return .init(done: true, target: target, id: id, kind: shown.kind.rawValue, waiting: panel ? true : nil,
                     inside: appeared.map(UITargetView.init),
                     message: panel ? "the panel waits for the person: they choose, or close_ui closes it as Cancel" : nil)
    }

    /// Opens an element's right-click menu, which waits for the person — or
    /// closes it as Esc does (plan 30 T2).
    @MainActor
    private func rightClickMenu(of element: UIElement, open: Bool, target: String) async -> OpenCloseUITool.Output {
        let presenter = uiHintPresenter
        if !open, presenter.cancelOpenMenus() { return .init(done: true, target: target, id: element.id, kind: "menu") }
        if open {
            var current = element
            if !element.inSight, let moved = await presenter.bringIntoView([element])[element.id] { current = moved }
            let (done, appeared) = await presenter.showMenu(current)
            if done {
                agentsService.activityStore.append(.live(kind: "open_ui", summary: "Opened the menu of \(current.name ?? current.id)",
                                                         origin: .external(clientID: "open_ui")))
                return .init(done: true, target: target, id: current.id, kind: "menu", waiting: true,
                             inside: appeared.map(UITargetView.init),
                             message: "its right-click menu waits for the person: they choose from it or press Esc; close_ui `menu` closes it")
            }
        }
        let navigate = element.kind == .tab || element.kind == .segment
            ? "a tab is navigated to, never opened: navigate_to, select_search_tab or open_settings"
            : "open_ui opens a folded section, a hidden panel, a menu, what a control opens (`opens`) or a right-click menu, and this has none"
        return .init(done: false, target: target, id: element.id, kind: element.kind.rawValue,
                     message: "\(element.id) is a \(element.kind.rawValue): \(navigate)")
    }

    func makeClearUIHintsTool() -> ClearUIHintsTool {
        ClearUIHintsTool(clear: { [weak self] args in
            await MainActor.run { self?.clearUIHints(args) ?? .init(cleared: 0, left: 0) }
        })
    }

    /// Reads the screen, finds each hint's element — scrolling one out of
    /// sight into view first — shows them as one set, and says how each was
    /// drawn.
    @MainActor
    func showUIHints(_ args: ShowUIHintsTool.Args) async -> ShowUIHintsTool.Output {
        let presenter = uiHintPresenter
        await presenter.ready()
        var snapshot = presenter.snapshot()
        // Targets scrolled out of sight come into view first; then the screen
        // is read again. Each target is found again by identity, not by its
        // name: a derived id ("Relaunch#5") counts what is in sight, and that
        // changed — and one in sight before may have scrolled away for another.
        let matched = (args.hints ?? []).prefix(ShowUIHintsTool.maxHints).compactMap { hint -> (String, UIElement)? in
            if case .found(let element) = UITargetScope.match(hint.target, in: snapshot) { return (hint.target, element) }
            return nil
        }
        var now: [String: UIElement] = [:]
        var wasInSight: [String: Bool] = [:]
        if matched.contains(where: { !$0.1.inSight }) {
            let found = await presenter.bringIntoView(matched.map(\.1))
            snapshot = presenter.lastSnapshot
            for (target, element) in matched {
                now[target] = found[element.id]
                wasInSight[target] = element.inSight
            }
        }
        var output = ShowUIHintsTool.Output()
        var requests: [UIHintPresenter.Request] = []
        var asked: [String: String] = [:]

        if let all = args.all {
            let scoped = UITargetScope.filter(UITargetScope.elements(snapshot, window: nil),
                                              kind: all.kind ?? .interactive, screen: all.screen, contains: all.contains)
            requests += scoped.prefix(ShowUIHintsTool.maxRings).map { .init(element: $0, title: nil, text: nil, style: .ring) }
            output.dropped = max(0, scoped.count - ShowUIHintsTool.maxRings)
        }
        for hint in (args.hints ?? []).prefix(ShowUIHintsTool.maxHints) {
            let match = now[hint.target].map(UITargetScope.Match.found) ?? UITargetScope.match(hint.target, in: snapshot)
            switch match {
            case .found(let element) where !element.inSight:
                let reason = wasInSight[hint.target] == true
                    ? "went out of sight to bring the others into view: they do not fit in sight together — show it on its own"
                    : "is scrolled out of sight and could not be brought into view"
                output.missing.append(.init(target: hint.target, candidates: [], closed: [], reason: reason))
                output.message = "\(hint.target) \(reason)"
            case .found(let element):
                let words = hint.text != nil || hint.title != nil
                requests.removeAll { $0.element.id == element.id }
                requests.append(.init(element: element, title: hint.title, text: hint.text,
                                      style: hint.style ?? (words ? .bubble : .ring)))
                asked[element.id] = hint.target
            case .missing(let candidates, let closed):
                output.missing.append(.init(target: hint.target, candidates: candidates.map(UITargetView.init),
                                            closed: closed.map(UITargetView.init)))
            }
        }
        output.dropped += max(0, (args.hints?.count ?? 0) - ShowUIHintsTool.maxHints)
        guard !requests.isEmpty else {
            output.message = output.message ?? snapshot.problem ?? (snapshot.elements.isEmpty
                ? "nothing on screen to hint — navigate_to or open_settings first"
                : "no hint could be shown: see `missing`")
            return output
        }

        let set = presenter.show(
            requests, numbered: args.numbered ?? false, dim: args.dim ?? false,
            seconds: UIHintStore.seconds(asked: args.seconds, untilClosed: args.untilClosed ?? false,
                                         bubbles: requests.contains { $0.style == .bubble }),
            replace: args.mode == "replace")
        presenter.render()
        output.set = set
        for hint in uiHints.hints(in: set) {
            let scene = presenter.scene(on: hint.window)
            let entry = scene?.entries.first { $0.id == hint.id }
            let drawn = scene?.bubbles.contains { $0.id == hint.id } == true ? "bubble" : entry != nil ? "list" : "ring"
            output.shown.append(.init(target: asked[hint.id] ?? hint.id, id: hint.id, as: drawn,
                                      number: entry?.number ?? hint.number))
        }
        output.listed = output.shown.filter { $0.as == "list" }.count
        let named = requests.compactMap { $0.element.name }.prefix(3).joined(separator: ", ")
        agentsService.activityStore.append(.live(
            kind: "show_ui_hints",
            summary: requests.count == 1 ? "Pointed at \(named)" : "Showed \(requests.count) hints",
            origin: .external(clientID: "show_ui_hints")))
        return output
    }

    @MainActor
    func clearUIHints(_ args: ClearUIHintsTool.Args) -> ClearUIHintsTool.Output {
        let before = uiHints.hints.count
        if let set = args.set {
            uiHints.clear(set: set)
        } else if let targets = args.targets {
            let up = uiHints.hints.map { UIPointerMatcher.Target(id: $0.id, label: $0.id, screen: $0.screen) }
            let ids = Set(targets.compactMap { UIPointerMatcher.best(up, for: $0)?.id })
            uiHints.clear(ids: ids)
        } else {
            uiHints.clearAll()
        }
        return .init(cleared: before - uiHints.hints.count, left: uiHints.hints.count)
    }

    func makeOpenSettingsTool() -> LiveActionTool<SettingsActions.OpenArgs> {
        SettingsActions.open { [weak self] args in
            guard let self else { return "App state unavailable" }
            let section: SettingsSection?
            if let raw = args.section {
                guard let known = SettingsSection(rawValue: raw) else { return "no Settings section \"\(raw)\"" }
                section = known
            } else {
                section = nil
            }
            await MainActor.run {
                self.requestSettings(.open, section: section)
                self.agentsService.activityStore.append(.live(
                    kind: "open_settings", summary: "Opened Settings", origin: .external(clientID: "open_settings")))
            }
            return nil
        }
    }

    func makeCloseSettingsTool() -> LiveActionTool<SettingsActions.NoArgs> {
        SettingsActions.close { [weak self] _ in
            guard let self else { return "App state unavailable" }
            await MainActor.run { self.requestSettings(.close) }
            return nil
        }
    }
}
