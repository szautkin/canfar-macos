// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation
import VerbinalKit

/// What one window's hint overlay draws, placed (plan 27): rings, bubbles,
/// badges and the hint list, in the window's points, top-left origin. Built
/// by the presenter from the store and the layout; drawn as it is.
struct UIHintScene: Equatable, Sendable {
    struct Ring: Equatable, Sendable {
        let id: String
        let frame: CGRect
        /// An area holding other hinted elements: dashed, so nested rings do
        /// not read as one.
        let dashed: Bool
    }

    struct Bubble: Equatable, Sendable {
        let id: String
        let frame: CGRect
        let side: UIHintLayout.Side
        let anchor: CGPoint
        let line: Bool
        let title: String?
        let text: String?
        let number: Int?
    }

    struct Badge: Equatable, Sendable {
        let id: String
        let frame: CGRect
        let number: Int
    }

    struct Entry: Equatable, Sendable, Identifiable {
        let id: String
        let number: Int
        let title: String?
        let text: String?
    }

    var size: CGSize = .zero
    var dim = false
    var rings: [Ring] = []
    var bubbles: [Bubble] = []
    var badges: [Badge] = []
    /// The hint list: its entries, and where it sits — or, with no room, the pill.
    var entries: [Entry] = []
    var listFrame: CGRect?
    var pillFrame: CGRect?

    var isEmpty: Bool { rings.isEmpty && bubbles.isEmpty && badges.isEmpty && entries.isEmpty }

    /// What takes the mouse: the bubbles, the list, the pill. The rest clicks
    /// through to the app.
    var interactive: [CGRect] { bubbles.map(\.frame) + [listFrame, pillFrame].compactMap { $0 } }

    // MARK: - Building

    /// The scene for one window's hints.
    /// - Parameters:
    ///   - measure: a bubble's size for its words, and a list entry's height.
    ///   - previous: where each bubble sat relative to its element last time.
    @MainActor
    static func build(hints: [UIHint], sets: [String: UIHintSet], size: CGSize,
                      controls: [CGRect], images: [CGRect], previous: [String: CGRect],
                      measure: UIHintMeasuring) -> UIHintScene {
        var scene = UIHintScene(size: size)
        guard !hints.isEmpty else { return scene }
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        scene.dim = hints.contains { sets[$0.set]?.dim == true }
        scene.rings = hints.map { hint in
            let others = hints.filter { $0.id != hint.id }
            return Ring(id: hint.id, frame: hint.frame,
                        dashed: hint.kind == .area && others.contains { hint.frame.contains($0.frame) })
        }
        let layoutHints = hints.map { hint in
            UIHintLayout.Hint(id: hint.id, target: hint.frame.insetBy(dx: -UIHintMeasure.ringOutset, dy: -UIHintMeasure.ringOutset),
                              bubble: hint.style == .bubble && (hint.text != nil || hint.title != nil)
                                  ? measure.bubble(title: hint.title, text: hint.text, numbered: hint.number != nil) : nil,
                              previous: previous[hint.id])
        }
        let placement = UIHintLayout.place(.init(bounds: bounds, hints: layoutHints,
                                                 controls: controls, images: images))
        let byID = Dictionary(hints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        scene.bubbles = hints.compactMap { hint in
            placement.bubbles[hint.id].map { placed in
                Bubble(id: hint.id, frame: placed.frame, side: placed.side, anchor: placed.anchor, line: placed.line,
                       title: hint.title, text: hint.text, number: hint.number)
            }
        }
        // Listed hints are numbered by their set's numbers, or in list order.
        var number = 0
        scene.entries = placement.listed.compactMap { id in
            guard let hint = byID[id] else { return nil }
            number += 1
            return Entry(id: id, number: hint.number ?? number, title: hint.title, text: hint.text)
        }
        let numbers = Dictionary(scene.entries.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        scene.badges = placement.badges.compactMap { id, frame in
            numbers[id].map { Badge(id: id, frame: frame, number: $0) }
        }.sorted { $0.number < $1.number }
        if !scene.entries.isEmpty {
            let keepClear = hints.map(\.frame) + scene.bubbles.map(\.frame) + scene.badges.map(\.frame)
            let listSize = measure.list(scene.entries, maxHeight: size.height * 0.6)
            scene.listFrame = UIHintLayout.placeList(size: listSize, in: bounds, keepClear: keepClear)
            if scene.listFrame == nil {
                scene.pillFrame = UIHintLayout.placeList(size: UIHintMeasure.pillSize, in: bounds, keepClear: keepClear)
                    ?? CGRect(origin: CGPoint(x: bounds.maxX - UIHintMeasure.pillSize.width, y: bounds.maxY - UIHintMeasure.pillSize.height),
                              size: UIHintMeasure.pillSize)
            }
        }
        return scene
    }
}

/// Sizes for the scene: a bubble for its words, the hint list for its
/// entries — measured as the overlay draws them.
@MainActor
protocol UIHintMeasuring {
    func bubble(title: String?, text: String?, numbered: Bool) -> CGSize
    func list(_ entries: [UIHintScene.Entry], maxHeight: CGFloat) -> CGSize
}
