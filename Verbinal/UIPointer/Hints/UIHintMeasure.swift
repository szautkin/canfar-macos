// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation

/// The sizes the overlay draws hints at, and the measuring of their words
/// (plan 27): one set of numbers for the layout and the drawing, so a
/// bubble is placed at the size it is drawn.
struct UIHintMeasure {
    static let ringOutset: CGFloat = 4
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 4
    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 300
    static let closeSize: CGFloat = 14
    static let numberSize: CGFloat = 18
    static let titleSize: CGFloat = 13
    static let textSize: CGFloat = 12
    static let listWidth: CGFloat = 260
    static let listHeader: CGFloat = 30
    static let pillSize = CGSize(width: 96, height: 26)
    /// At most this much of a hint's words in the hint list: it is a list.
    static let listLines = 3
    /// Words draw a point or two wider than they measure: room for that, so
    /// they never wrap onto a line the bubble was not given.
    static let slack: CGFloat = 2

    /// The width beside a bubble's words: its close button, and its number.
    static func extras(numbered: Bool) -> CGFloat {
        closeSize + spacing + (numbered ? numberSize + spacing * 2 : 0)
    }
}

#if os(macOS)
import AppKit

extension UIHintMeasure: UIHintMeasuring {
    static var titleFont: NSFont { .systemFont(ofSize: titleSize, weight: .semibold) }
    static var textFont: NSFont { .systemFont(ofSize: textSize) }

    func bubble(title: String?, text: String?, numbered: Bool) -> CGSize {
        let extras = Self.extras(numbered: numbered)
        let widest = Self.maxWidth - 2 * Self.padding - extras
        let narrowest = Self.minWidth - 2 * Self.padding - extras
        let natural = max(Self.width(title, Self.titleFont), Self.width(text, Self.textFont))
        let content = min(widest, max(narrowest, natural.rounded(.up) + Self.slack))
        let words = Self.height(title, Self.titleFont, content)
            + (title != nil && text != nil ? Self.spacing : 0)
            + Self.height(text, Self.textFont, content)
        let tallest = max(words, numbered ? Self.numberSize : Self.closeSize)
        return CGSize(width: content + extras + 2 * Self.padding, height: tallest + 2 * Self.padding)
    }

    func list(_ entries: [UIHintScene.Entry], maxHeight: CGFloat) -> CGSize {
        let content = Self.listWidth - 2 * Self.padding - Self.numberSize - Self.spacing * 2
        let lineHeight = Self.textFont.boundingRectForFont.height
        let rows = entries.reduce(CGFloat(0)) { sum, entry in
            let words = [entry.title, entry.text].compactMap { $0 }.joined(separator: " — ")
            let height = min(Self.height(words, Self.textFont, content), lineHeight * CGFloat(Self.listLines))
            return sum + max(height, Self.numberSize) + Self.spacing * 2
        }
        return CGSize(width: Self.listWidth, height: min(maxHeight, Self.listHeader + rows + Self.padding))
    }

    private static func width(_ text: String?, _ font: NSFont) -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func height(_ text: String?, _ font: NSFont, _ width: CGFloat) -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        let box = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  attributes: [.font: font])
        return box.height.rounded(.up) + 1
    }
}
#endif
