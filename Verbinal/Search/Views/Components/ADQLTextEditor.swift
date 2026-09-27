// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

#if os(macOS)
/// A plain-text editor that disables smart quotes, smart dashes, autocorrect,
/// and spell checking — suitable for editing ADQL/SQL code. Underlines the
/// checker's problems and selects one on request.
struct ADQLTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Character ranges to underline in red.
    var problems: [Range<Int>] = []
    /// Set to select and reveal that range; cleared once done.
    var select: Binding<Range<Int>?> = .constant(nil)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false

        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 4, height: 4)

        textView.delegate = context.coordinator
        textView.string = text

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selection
        }
        if let layout = textView.layoutManager {
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: whole)
            layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: whole)
            for range in problems.compactMap({ Self.nsRange($0, in: textView.string) }) {
                layout.addTemporaryAttributes(
                    [.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NSColor.systemRed],
                    forCharacterRange: range)
            }
        }
        if let wanted = select.wrappedValue, let range = Self.nsRange(wanted, in: textView.string) {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            DispatchQueue.main.async { select.wrappedValue = nil }
        }
    }

    /// Character offsets as the UTF-16 range AppKit uses.
    static func nsRange(_ range: Range<Int>, in text: String) -> NSRange? {
        guard let lower = text.index(text.startIndex, offsetBy: range.lowerBound, limitedBy: text.endIndex),
              let upper = text.index(text.startIndex, offsetBy: range.upperBound, limitedBy: text.endIndex)
        else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ADQLTextEditor

        init(_ parent: ADQLTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
#else
/// iOS fallback — standard TextEditor with autocorrect disabled. Problems
/// are listed under it rather than underlined.
struct ADQLTextEditor: View {
    @Binding var text: String
    var problems: [Range<Int>] = []
    var select: Binding<Range<Int>?> = .constant(nil)

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.caption, design: .monospaced))
            .scrollContentBackground(.hidden)
            .disableAutocorrection(true)
    }
}
#endif
