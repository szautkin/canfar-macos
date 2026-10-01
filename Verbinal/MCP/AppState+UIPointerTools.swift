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
        // is read again, and every target found anew where it is now.
        let away = (args.hints ?? []).prefix(ShowUIHintsTool.maxHints).compactMap { hint -> UIElement? in
            if case .found(let element) = UITargetScope.match(hint.target, in: snapshot), !element.inSight { return element }
            return nil
        }
        if !away.isEmpty {
            _ = await presenter.bringIntoView(away)
            snapshot = presenter.lastSnapshot
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
            switch UITargetScope.match(hint.target, in: snapshot) {
            case .found(let element) where !element.inSight:
                output.missing.append(.init(target: hint.target, candidates: [], closed: []))
                output.message = "\(hint.target) is scrolled out of sight and could not be brought into view"
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
            output.message = snapshot.problem ?? (snapshot.elements.isEmpty
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
