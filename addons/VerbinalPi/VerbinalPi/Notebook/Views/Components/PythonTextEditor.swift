// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

#if os(macOS)
import AppKit

/// NSTextView wrapper with Python syntax highlighting.
struct PythonTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return scrollView }

        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.textContainerInset = NSSize(width: 4, height: 2)
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.backgroundColor = .clear

        tv.delegate = context.coordinator
        tv.string = text
        context.coordinator.applyHighlighting(to: tv)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            context.coordinator.applyHighlighting(to: tv)
            tv.selectedRanges = sel
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PythonTextEditor
        private var isHighlighting = false

        init(_ parent: PythonTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, !isHighlighting else { return }
            parent.text = tv.string
            applyHighlighting(to: tv)
        }

        func applyHighlighting(to tv: NSTextView) {
            guard let storage = tv.textStorage, !isHighlighting else { return }
            isHighlighting = true
            defer { isHighlighting = false }

            let source = tv.string
            let fullRange = NSRange(location: 0, length: (source as NSString).length)

            storage.beginEditing()
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: fullRange)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

            for token in PythonHighlighter.tokens(in: source) {
                storage.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            }

            storage.endEditing()
        }
    }
}
#endif
