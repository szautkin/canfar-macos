// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import AppKit

/// Code as typed: no smart quotes or dashes, no text replacement or
/// autocorrection. SwiftUI's `TextEditor` follows the Mac's "Use smart
/// quotes and dashes", so `print("Hello")` left as `print(“Hello”)`, and a
/// curly quote in Python or Bash is a syntax error on the session.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// What VoiceOver and an assistant call it.
    let label: String
    /// Its hand-tagged id (plan 27), on the text view itself.
    var pointable: String? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.setAccessibilityLabel(label)
        if let pointable { textView.setAccessibilityIdentifier(PointableID.encode(pointable)) }

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 4, height: 6)

        textView.delegate = context.coordinator
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        context.coordinator.isSetting = true
        defer { context.coordinator.isSetting = false }
        Self.replaceAll(in: textView, with: text)
    }

    /// Text set from outside — Fix Characters, `set_compute_snippet` — as
    /// one edit ⌘Z takes back, the caret kept inside the new text.
    static func replaceAll(in textView: NSTextView, with text: String) {
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        let caret = min(textView.selectedRange().location, (text as NSString).length)
        textView.breakUndoCoalescing()
        if textView.shouldChangeText(in: whole, replacementString: text) {
            textView.replaceCharacters(in: whole, with: text)
            textView.didChangeText()
        } else {
            textView.string = text
        }
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// While the binding's own text goes in, so it is not sent back.
        var isSetting = false
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard !isSetting, let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
