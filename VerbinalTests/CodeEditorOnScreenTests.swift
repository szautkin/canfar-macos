// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// Remote Compute's code box keeps quotes as typed: `print("Hello")` ran as
/// `print(“Hello”)`, a syntax error on the session.
@MainActor
final class CodeEditorOnScreenTests: XCTestCase {
    private final class Box { var code = "" }

    private let typed = #"print("Hello", 'world') -- done"#

    /// Types `text`, then runs the Mac's text checking over it, as it does
    /// while a person types: smart quotes and dashes, text replacement. A
    /// test host's key presses alone never reach it.
    private func type(_ text: String, into textView: NSTextView) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.checkTextInDocument(nil)
    }

    func testQuotesAndDashesStayAsTyped() throws {
        let box = Box()
        let code = Binding(get: { box.code }, set: { box.code = $0 })
        let window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 460, height: 240), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CodeEditor(text: code, label: "Code to run", pointable: "compute.snippet"))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.layoutIfNeeded()

        let textView = try XCTUnwrap(Self.textView(in: try XCTUnwrap(window.contentView)))
        XCTAssertEqual(textView.accessibilityLabel(), "Code to run")
        XCTAssertEqual(textView.accessibilityIdentifier(), PointableID.encode("compute.snippet"))
        window.makeFirstResponder(textView)
        type(typed, into: textView)
        XCTAssertEqual(textView.string, typed)
        XCTAssertEqual(box.code, typed, "what is typed is what runs")
    }

    /// The test types the way a person does: a text view with smart quotes
    /// on curls them.
    func testATextViewWithSmartQuotesCurlsThem() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        let window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.makeFirstResponder(textView)
        type(typed, into: textView)
        XCTAssertNotEqual(textView.string, typed)
        XCTAssertTrue(textView.string.contains("“"), textView.string)
    }

    /// Fix Characters goes in as one edit: ⌘Z brings the pasted code back.
    func testTextSetFromOutsideIsOneUndo() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.allowsUndo = true
        let window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.makeFirstResponder(textView)
        // One undo group each, as the paste and the click are two events.
        let undo = try XCTUnwrap(textView.undoManager)
        undo.groupsByEvent = false
        let pasted = "print(“Hello world”)"
        undo.beginUndoGrouping()
        textView.insertText(pasted, replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()

        undo.beginUndoGrouping()
        CodeEditor.replaceAll(in: textView, with: PastedCode.fixed(pasted))
        undo.endUndoGrouping()
        XCTAssertEqual(textView.string, #"print("Hello world")"#)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 20, length: 0), "the caret stays inside the text")
        undo.undo()
        XCTAssertEqual(textView.string, pasted)
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap(textView).first
    }
}
