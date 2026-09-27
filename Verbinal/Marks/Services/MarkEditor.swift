// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation
import Observation

/// Marks being made and changed by hand on one viewer: the pencil, the
/// gesture under way, the mark being named, the style the next one gets.
///
/// One of these serves a viewer; the FITS canvas and the cube differ only
/// in the `MarkProjection` and `MarkStore.Target` they pass in (Windows
/// kept two copies of this and they drifted). No UI types, so the rules —
/// what a press means, when a mark is named, what is kept — are tested.
///
/// A gesture changes a copy (`live`) drawn in place of the stored mark; the
/// store, and the disk, are written once, when it ends.
@Observable @MainActor
final class MarkEditor {

    let store: MarkStore

    /// While armed, a press on empty image draws a mark instead of panning.
    /// Putting it down keeps whatever is being named.
    var drawArmed = false {
        didSet { if !drawArmed { finishNaming() } }
    }

    /// What the pencil draws.
    var kind: Mark.Kind = .circle

    /// How the next mark looks; remembered between launches.
    private(set) var nextStyle: Mark.Style

    /// A mark whose words are being typed. A shape is stored already; a
    /// callout or text needs words to be kept, so it waits here.
    struct Naming: Equatable {
        let target: MarkStore.Target
        var mark: Mark
        let stored: Bool
    }
    private(set) var naming: Naming?
    /// What the naming field shows and edits.
    var namingText = ""

    /// Why the last change was not kept, for the view to show; cleared on read.
    var problem: String?

    private var live: (target: MarkStore.Target, mark: Mark)?
    private var grab: MarkGeometry.Grab = .none
    private var pressPoint = CGPoint.zero
    private var pressMoved = false
    /// The press was on the mark already picked out: a click lets it go.
    private var pressOnSelected = false
    private var placing = false

    private let defaults: UserDefaults
    static let styleKey = "marks.nextStyle"

    init(store: MarkStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        nextStyle = defaults.data(forKey: Self.styleKey)
            .flatMap { try? JSONDecoder().decode(Mark.Style.self, from: $0) }?.sane() ?? .userDefault
    }

    // MARK: - What is shown

    /// The marks to draw on `target`: the stored ones, with the one being
    /// dragged or named in its current state.
    func marks(on target: MarkStore.Target) -> [Mark] {
        var marks = store.marks(on: target)
        for (t, mark) in [live, naming.map { ($0.target, $0.mark) }].compactMap({ $0 }) where t == target {
            if let i = marks.firstIndex(where: { $0.id == mark.id }) { marks[i] = mark } else { marks.append(mark) }
        }
        return marks
    }

    func selectedID(on target: MarkStore.Target) -> String? {
        store.selected?.target == target ? store.selected?.id : nil
    }

    func selected(on target: MarkStore.Target) -> Mark? {
        selectedID(on: target).flatMap { id in marks(on: target).first { $0.id == id } }
    }

    // MARK: - Gestures

    /// A press. True when the marks take it — the view must then not pan.
    func press(at point: CGPoint, on target: MarkStore.Target, projection: MarkProjection) -> Bool {
        finishNaming()
        let marks = self.marks(on: target)
        let selectedID = selectedID(on: target)
        pressPoint = point
        pressMoved = false
        pressOnSelected = false
        placing = false
        grab = MarkGeometry.grab(at: point, in: marks, projection: projection, selectedID: selectedID, drawing: drawArmed)

        switch grab {
        case .none:
            // Pressing away from the marks lets the picked-out one go; the
            // press is still the view's.
            if selectedID != nil { store.selected = nil }
            return false

        case .place:
            guard let anchor = projection.anchor(point, nil) else { grab = .none; return false }
            let sized = kind != .text
            let half = sized ? MarkGeometry.units(MarkGeometry.initialHalf, at: anchor, projection: projection) : nil
            guard !sized || half != nil else { grab = .none; return false }
            let mark = Mark(id: store.newID(on: target), kind: kind, anchor: anchor, extent: half.map(Mark.Extent.square),
                            author: .user, style: nextStyle, createdAt: Date())
            store.selected = (target, mark.id)
            guard sized else {
                // Nothing to drag out: name it now.
                grab = .none
                naming = Naming(target: target, mark: mark, stored: false)
                namingText = ""
                return true
            }
            live = (target, mark)
            placing = true
            grab = .resize(id: mark.id)
            return true

        case .move(let id, _):
            pressOnSelected = selectedID == id
            store.selected = (target, id)
            live = marks.first { $0.id == id }.map { (target, $0) }
            return true

        case .resize(let id):
            live = marks.first { $0.id == id }.map { (target, $0) }
            return true
        }
    }

    /// The pointer moved with the button down. True while the marks have it.
    @discardableResult
    func drag(to point: CGPoint, projection: MarkProjection) -> Bool {
        guard grab != .none else { return false }
        if hypot(point.x - pressPoint.x, point.y - pressPoint.y) > MarkGeometry.clickSlop { pressMoved = true }
        guard pressMoved, let (target, current) = live else { return true }
        var mark = current
        switch grab {
        case .move(_, let offset):
            let at = CGPoint(x: point.x - offset.width, y: point.y - offset.height)
            if let anchor = projection.anchor(at, mark.anchor) { mark.anchor = anchor }
        case .resize:
            if let extent = MarkGeometry.resized(mark, to: point, projection: projection) { mark.extent = extent }
        case .none, .place:
            break
        }
        live = (target, mark)
        return true
    }

    /// The button came up. True if the marks had the pointer.
    @discardableResult
    func release() -> Bool {
        guard grab != .none else { return false }
        let wasMove: Bool
        if case .move = grab { wasMove = true } else { wasMove = false }
        let letGo = wasMove && pressOnSelected && !pressMoved
        let finished = live
        grab = .none
        live = nil
        defer { placing = false }

        guard let (target, mark) = finished else { return true }
        if placing {
            // Sizing it finished drawing it: now its words. A callout needs
            // them to be kept; a shape is kept already, and may have none.
            if mark.kind == .callout {
                naming = Naming(target: target, mark: mark, stored: false)
            } else if keep({ try store.add(mark, to: target) }) {
                naming = Naming(target: target, mark: mark, stored: true)
            }
            namingText = ""
        } else if pressMoved {
            keep { try store.update(mark.id, on: target) { $0 = mark } }
        }
        if letGo { store.selected = nil }
        return true
    }

    // MARK: - Naming

    /// Open the naming field on a stored mark (double-click, "Edit Label").
    func beginNaming(_ id: String, on target: MarkStore.Target) {
        finishNaming()
        guard let mark = store.marks(on: target).first(where: { $0.id == id }) else { return }
        store.selected = (target, id)
        naming = Naming(target: target, mark: mark, stored: true)
        namingText = mark.text
    }

    /// Enter: keep the words. A callout or text left without any is not a
    /// mark that can be kept, so it goes.
    func commitNaming() {
        guard var current = naming else { return }
        naming = nil
        current.mark.text = namingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.stored {
            keep { try store.update(current.mark.id, on: current.target) { $0.text = current.mark.text } }
        } else if current.mark.problem == nil {
            keep { try store.add(current.mark, to: current.target) }
        } else if store.selected?.id == current.mark.id {
            store.selected = nil
        }
    }

    /// Escape: the mark stays as it was (an unnamed callout, never kept, goes).
    func cancelNaming() {
        guard let current = naming else { return }
        naming = nil
        if !current.stored, store.selected?.id == current.mark.id { store.selected = nil }
    }

    /// The bin in the naming field.
    func deleteNaming() {
        guard let current = naming else { return }
        naming = nil
        if current.stored { delete(current.mark.id, on: current.target) }
        else if store.selected?.id == current.mark.id { store.selected = nil }
    }

    /// Anything else happening keeps what was typed.
    func finishNaming() {
        if naming != nil { commitNaming() }
    }

    // MARK: - Panel and menu

    /// Pick a mark out (nil lets go).
    func select(_ id: String?, on target: MarkStore.Target) {
        finishNaming()
        store.selected = id.map { (target, $0) }
    }

    func delete(_ id: String, on target: MarkStore.Target) {
        if naming?.mark.id == id { naming = nil }
        keep { try store.remove(id, from: target) }
    }

    func deleteSelected(on target: MarkStore.Target) -> Bool {
        guard let id = selectedID(on: target) else { return false }
        delete(id, on: target)
        return true
    }

    /// Escape: put the pencil down, else let the picked-out mark go.
    /// False when there was nothing to do, so the key goes on.
    func escape(on target: MarkStore.Target) -> Bool {
        if drawArmed {
            drawArmed = false
            return true
        }
        guard selectedID(on: target) != nil else { return false }
        select(nil, on: target)
        return true
    }

    func clear(_ target: MarkStore.Target) {
        naming = nil
        store.clear([target])
    }

    /// The style the controls show: the picked-out mark's, else the next one's.
    func style(on target: MarkStore.Target?) -> Mark.Style {
        target.flatMap { selected(on: $0)?.effectiveStyle } ?? nextStyle
    }

    /// Restyles the picked-out mark, or — with none — the next one, as
    /// every drawing application does.
    func applyStyle(_ style: Mark.Style, on target: MarkStore.Target?) {
        let style = style.sane()
        if let target, let id = selectedID(on: target), naming?.mark.id != id {
            keep { try store.update(id, on: target) { $0.style = style } }
        } else if var current = naming {
            current.mark.style = style
            naming = current
            if current.stored { keep { try store.update(current.mark.id, on: current.target) { $0.style = style } } }
        } else {
            nextStyle = style
            if let data = try? JSONEncoder().encode(style) { defaults.set(data, forKey: Self.styleKey) }
        }
    }

    /// Runs a store change; a refusal becomes `problem` rather than vanishing.
    @discardableResult
    private func keep(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            return true
        } catch {
            problem = (error as? MarkStore.Failure)?.message ?? error.localizedDescription
            return false
        }
    }
}
