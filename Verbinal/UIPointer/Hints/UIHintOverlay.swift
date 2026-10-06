// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// What the person does to hints on screen, handed back to the presenter.
struct UIHintActions {
    let close: (String) -> Void
    let closeAll: (_ window: Int) -> Void
    let hover: (_ id: String?) -> Void
}

/// Draws each window's hints in a transparent panel over it — a child of
/// the window, so it moves with it (plan 27 O). Only the bubbles, the hint
/// list and its pill take the mouse; everywhere else clicks through to the
/// app.
@MainActor
final class UIHintOverlay {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        /// Not a window to list: it shares its window's frame, and would read
        /// as that window. VoiceOver hears hints as announcements.
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? { nil }
    }

    @Observable
    @MainActor
    final class Model {
        var scene = UIHintScene()
        /// The bubble or list under the mouse.
        var hovering: String?
    }

    private var panels: [Int: (panel: NSPanel, model: Model)] = [:]
    private let actions: UIHintActions

    init(actions: UIHintActions) {
        self.actions = actions
    }

    /// The windows drawn over now.
    var windows: [Int] { Array(panels.keys) }

    func scene(on window: Int) -> UIHintScene? { panels[window]?.model.scene }

    /// Shows each window's scene; takes down the panels of windows with none.
    func render(_ scenes: [Int: UIHintScene]) {
        for (number, entry) in panels where scenes[number]?.isEmpty != false {
            entry.panel.parent?.removeChildWindow(entry.panel)
            entry.panel.orderOut(nil)
            panels[number] = nil
        }
        for (number, scene) in scenes where !scene.isEmpty {
            guard let parent = NSApp.window(withWindowNumber: number) else { continue }
            let entry = panels[number] ?? makePanel(over: parent, number: number)
            panels[number] = entry
            if entry.panel.frame != parent.frame { entry.panel.setFrame(parent.frame, display: false) }
            // Over an open menu, the hints draw above it.
            let level: NSWindow.Level = scene.aboveMenus ? NSWindow.Level(NSWindow.Level.popUpMenu.rawValue + 1) : parent.level
            if entry.panel.level != level { entry.panel.level = level }
            if entry.model.scene != scene { entry.model.scene = scene }
            if entry.panel.parent !== parent { parent.addChildWindow(entry.panel, ordered: .above) }
        }
    }

    /// Lets the mouse reach a bubble or the list, and says which one it is
    /// over; everything else clicks through.
    func trackMouse() {
        let mouse = NSEvent.mouseLocation
        var over: String?
        for (_, entry) in panels {
            let frame = entry.panel.frame
            let point = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
            let scene = entry.model.scene
            let bubble = scene.bubbles.first { $0.frame.contains(point) }?.id
            let list = (scene.listFrame?.contains(point) == true || scene.pillFrame?.contains(point) == true) ? "list" : nil
            let here = bubble ?? list
            let takes = here != nil || (entry.model.hovering == "list" && Self.openList(scene)?.contains(point) == true)
            if entry.panel.ignoresMouseEvents == takes { entry.panel.ignoresMouseEvents = !takes }
            let hovering = here ?? (takes ? entry.model.hovering : nil)
            if entry.model.hovering != hovering { entry.model.hovering = hovering }
            if let here { over = here }
        }
        actions.hover(over == "list" ? nil : over)
    }

    func removeAll() { render([:]) }

    /// Where the list opens from its pill: above it, as tall as it needs.
    static func openList(_ scene: UIHintScene) -> CGRect? {
        guard let pill = scene.pillFrame else { return nil }
        let height = min(scene.size.height * 0.6, UIHintMeasure.listHeader + CGFloat(scene.entries.count) * 40)
        let x = min(max(8, pill.maxX - UIHintMeasure.listWidth), scene.size.width - UIHintMeasure.listWidth - 8)
        return CGRect(x: x, y: max(8, pill.minY - height - 6), width: UIHintMeasure.listWidth, height: height)
    }

    private func makePanel(over parent: NSWindow, number: Int) -> (panel: NSPanel, model: Model) {
        let panel = Panel(contentRect: parent.frame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier(PointableID.Window.hints.identifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        let model = Model()
        let actions = actions
        panel.contentView = NSHostingView(rootView: UIHintCanvas(
            model: model,
            close: actions.close,
            closeAll: { actions.closeAll(number) }))
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        return (panel, model)
    }
}

// MARK: - The drawing

private struct UIHintCanvas: View {
    let model: UIHintOverlay.Model
    let close: (String) -> Void
    let closeAll: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    private var scene: UIHintScene { model.scene }
    private var lineWidth: CGFloat { contrast == .increased ? 4 : 2.5 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if scene.dim { dim }
            ForEach(scene.rings, id: \.id) { ring in
                let frame = ring.frame.insetBy(dx: -UIHintMeasure.ringOutset, dy: -UIHintMeasure.ringOutset)
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, dash: ring.dashed ? [6, 4] : []))
                    .shadow(color: .accentColor.opacity(0.45), radius: 4)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
            tails
            ForEach(scene.bubbles, id: \.id) { bubble in
                UIHintBubbleView(bubble: bubble, close: { close(bubble.id) })
                    .frame(width: bubble.frame.width, height: bubble.frame.height, alignment: .topLeading)
                    .offset(x: bubble.frame.minX, y: bubble.frame.minY)
            }
            ForEach(scene.badges, id: \.id) { badge in
                UIHintNumber(number: badge.number)
                    .frame(width: badge.frame.width, height: badge.frame.height)
                    .offset(x: badge.frame.minX, y: badge.frame.minY)
            }
            if let frame = scene.listFrame ?? (model.hovering == "list" ? UIHintOverlay.openList(scene) : nil) {
                UIHintList(entries: scene.entries, closeAll: closeAll)
                    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                    .offset(x: frame.minX, y: frame.minY)
            }
            if let pill = scene.pillFrame {
                Text("\(scene.entries.count) hints")
                    .font(.caption.weight(.semibold))
                    .frame(width: pill.width, height: pill.height)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.accentColor))
                    .offset(x: pill.minX, y: pill.minY)
            }
        }
        .frame(width: scene.size.width, height: scene.size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: scene)
    }

    /// The spotlight: the window shaded, the hinted elements clear.
    private var dim: some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            for ring in scene.rings {
                path.addRoundedRect(in: ring.frame.insetBy(dx: -UIHintMeasure.ringOutset, dy: -UIHintMeasure.ringOutset),
                                    cornerSize: CGSize(width: 6, height: 6))
            }
            context.fill(path, with: .color(.black.opacity(UIHintMeasure.dimming(dark: colorScheme == .dark))),
                         style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    /// A tail from each bubble to its element; a line, with a dot, when the
    /// bubble sits away from it.
    private var tails: some View {
        Canvas { context, _ in
            for bubble in scene.bubbles {
                let edge = Self.edge(bubble)
                if bubble.line {
                    var line = Path()
                    line.move(to: edge.middle)
                    line.addLine(to: bubble.anchor)
                    context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
                    context.fill(Path(ellipseIn: CGRect(x: bubble.anchor.x - 3, y: bubble.anchor.y - 3, width: 6, height: 6)),
                                 with: .color(.accentColor))
                } else {
                    var tail = Path()
                    tail.move(to: edge.a)
                    tail.addLine(to: bubble.anchor)
                    tail.addLine(to: edge.b)
                    tail.closeSubpath()
                    context.fill(tail, with: .color(.accentColor))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The facing edge of a bubble: its middle, and a tail's base (two
    /// points 7 pt apart either side of where the element is).
    private static func edge(_ bubble: UIHintScene.Bubble) -> (middle: CGPoint, a: CGPoint, b: CGPoint) {
        let f = bubble.frame
        switch bubble.side {
        case .below, .above:
            let y = bubble.side == .below ? f.minY : f.maxY
            let x = min(max(bubble.anchor.x, f.minX + 12), f.maxX - 12)
            return (CGPoint(x: f.midX, y: y), CGPoint(x: x - 7, y: y), CGPoint(x: x + 7, y: y))
        case .left, .right:
            let x = bubble.side == .right ? f.minX : f.maxX
            let y = min(max(bubble.anchor.y, f.minY + 12), f.maxY - 12)
            return (CGPoint(x: x, y: f.midY), CGPoint(x: x, y: y - 7), CGPoint(x: x, y: y + 7))
        }
    }
}

private struct UIHintNumber: View {
    let number: Int
    var body: some View {
        Text("\(number)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: UIHintMeasure.numberSize, height: UIHintMeasure.numberSize)
            .background(Circle().fill(Color.accentColor))
    }
}

/// A bubble, drawn at the size it was measured and placed at.
struct UIHintBubbleView: View {
    let bubble: UIHintScene.Bubble
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: UIHintMeasure.spacing) {
            if let number = bubble.number {
                UIHintNumber(number: number)
                    .padding(.trailing, UIHintMeasure.spacing)
            }
            VStack(alignment: .leading, spacing: UIHintMeasure.spacing) {
                if let title = bubble.title {
                    Text(title).font(.system(size: UIHintMeasure.titleSize, weight: .semibold))
                }
                if let text = bubble.text {
                    Text(text).font(.system(size: UIHintMeasure.textSize))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                // Exactly as wide as measured: a symbol draws wider than its size.
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIHintMeasure.closeSize, height: UIHintMeasure.closeSize)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close hint"))
        }
        .padding(UIHintMeasure.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }
}

private struct UIHintList: View {
    let entries: [UIHintScene.Entry]
    let closeAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hints").font(.headline)
                Spacer()
                Button(action: closeAll) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close all hints"))
            }
            .frame(height: UIHintMeasure.listHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: UIHintMeasure.spacing * 2) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: UIHintMeasure.spacing * 2) {
                            UIHintNumber(number: entry.number)
                            Text([entry.title, entry.text].compactMap { $0 }.joined(separator: " — "))
                                .font(.system(size: UIHintMeasure.textSize))
                                .lineLimit(UIHintMeasure.listLines)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, UIHintMeasure.padding)
        .padding(.bottom, UIHintMeasure.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1.5))
    }
}
#endif
