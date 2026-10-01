// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

#if os(macOS)
import AppKit

/// Names the text view behind a SwiftUI `TextEditor`. On macOS, SwiftUI
/// keeps a `TextEditor`'s accessibility label and identifier off the
/// `NSTextView` it draws with, so VoiceOver says only "text entry area" and
/// an assistant has nothing to call it by (plan 27). The probe sits behind
/// the editor, the same size, and names the text view whose scroll view
/// covers it.
private struct TextViewNamer: NSViewRepresentable {
    let label: String
    let identifier: String?

    final class Probe: NSView {
        var label = ""
        var pointableID: String?
        private weak var named: NSTextView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            nameSoon()
        }

        override func layout() {
            super.layout()
            nameSoon()
        }

        func nameSoon() {
            DispatchQueue.main.async { [weak self] in self?.name() }
        }

        private func name() {
            guard let root = window?.contentView else { return }
            let mine = convert(bounds, to: nil)
            guard mine.width > 0, mine.height > 0 else { return }
            let textView = named.flatMap { Self.covers($0, mine) ? $0 : nil }
                ?? Self.textViews(in: root).max { Self.overlap($0, mine) < Self.overlap($1, mine) }
            guard let textView, Self.covers(textView, mine) else { return }
            named = textView
            if textView.accessibilityLabel() != label { textView.setAccessibilityLabel(label) }
            if let pointableID, textView.accessibilityIdentifier() != pointableID {
                textView.setAccessibilityIdentifier(pointableID)
            }
        }

        private static func textViews(in view: NSView) -> [NSTextView] {
            if let textView = view as? NSTextView { return [textView] }
            return view.subviews.flatMap(textViews)
        }

        /// How much of the probe the text view's scroll view covers.
        private static func overlap(_ textView: NSTextView, _ frame: CGRect) -> CGFloat {
            let shown = textView.enclosingScrollView ?? textView
            let common = shown.convert(shown.bounds, to: nil).intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }

        /// Most of the probe, and most of the text view: the editor itself,
        /// not a neighbour that touches it.
        private static func covers(_ textView: NSTextView, _ frame: CGRect) -> Bool {
            let shown = textView.enclosingScrollView ?? textView
            let its = shown.convert(shown.bounds, to: nil)
            let common = overlap(textView, frame)
            return common > 0.6 * frame.width * frame.height && common > 0.6 * its.width * its.height
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        update(probe)
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        update(probe)
        probe.nameSoon()
    }

    private func update(_ probe: Probe) {
        probe.label = label
        probe.pointableID = identifier
    }
}
#endif

extension View {
    /// Names a `TextEditor` for VoiceOver and for an assistant — `label` is
    /// the caption a person reads for it, `pointable` its hand-tagged id.
    /// Put it straight after the `TextEditor`, before padding, so the two
    /// are the same size.
    func textEditorName(_ label: String, pointable: String? = nil) -> some View {
        #if os(macOS)
        background(TextViewNamer(label: label, identifier: pointable.map { PointableID.encode($0) })
            .accessibilityHidden(true))
        #else
        accessibilityLabel(Text(label))
        #endif
    }
}
