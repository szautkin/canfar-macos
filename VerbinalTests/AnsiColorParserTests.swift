// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class AnsiColorParserTests: XCTestCase {

    func testStripRemovesAllEscapes() {
        let input = "\u{1b}[31mError\u{1b}[0m: something failed"
        let stripped = AnsiColorParser.strip(input)
        XCTAssertEqual(stripped, "Error: something failed")
    }

    func testStripPlainText() {
        XCTAssertEqual(AnsiColorParser.strip("no codes here"), "no codes here")
    }

    func testStripEmpty() {
        XCTAssertEqual(AnsiColorParser.strip(""), "")
    }

    #if os(macOS)
    func testParseProducesAttributedString() {
        let input = "\u{1b}[31mred text\u{1b}[0m normal"
        let result = AnsiColorParser.parse(input)
        XCTAssertTrue(result.length > 0)
        XCTAssertTrue(result.string.contains("red text"))
        XCTAssertTrue(result.string.contains("normal"))
    }

    func testParsePlainTextNoEscapes() {
        let result = AnsiColorParser.parse("plain text")
        XCTAssertEqual(result.string, "plain text")
    }
    #endif
}

final class SimpleHtmlRendererTests: XCTestCase {

    func testRenderStripsTags() {
        let html = "<b>bold</b> and <i>italic</i>"
        let result = SimpleHtmlRenderer.render(html)
        XCTAssertTrue(result.contains("bold"))
        XCTAssertTrue(result.contains("italic"))
        XCTAssertFalse(result.contains("<b>"))
    }

    func testRenderDecodesEntities() {
        let html = "a &amp; b &lt; c"
        let result = SimpleHtmlRenderer.render(html)
        XCTAssertTrue(result.contains("a & b < c"))
    }

    func testContainsHTML() {
        XCTAssertTrue(SimpleHtmlRenderer.containsHTML("<table><tr><td>1</td></tr></table>"))
        XCTAssertFalse(SimpleHtmlRenderer.containsHTML("plain text"))
    }

    func testRenderLineBreaks() {
        let html = "line1<br>line2"
        let result = SimpleHtmlRenderer.render(html)
        XCTAssertTrue(result.contains("\n"))
    }
}

final class RecentNotebooksServiceTests: XCTestCase {

    private func makeService() -> RecentNotebooksService {
        RecentNotebooksService(fileName: "test_recent_nb_\(UUID().uuidString).json")
    }

    override func tearDown() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal/Notebook") {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("test_recent_nb_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        super.tearDown()
    }

    func testAddEntry() {
        let service = makeService()
        service.add(url: URL(fileURLWithPath: "/tmp/test.ipynb"))
        XCTAssertEqual(service.entries.count, 1)
        XCTAssertEqual(service.entries[0].name, "test.ipynb")
    }

    func testMaxEntries() {
        let service = makeService()
        for i in 0..<20 {
            service.add(url: URL(fileURLWithPath: "/tmp/nb\(i).ipynb"))
        }
        XCTAssertEqual(service.entries.count, 15)
    }

    func testDeduplication() {
        let service = makeService()
        service.add(url: URL(fileURLWithPath: "/tmp/a.ipynb"))
        service.add(url: URL(fileURLWithPath: "/tmp/b.ipynb"))
        service.add(url: URL(fileURLWithPath: "/tmp/a.ipynb"))
        XCTAssertEqual(service.entries.count, 2)
        XCTAssertEqual(service.entries[0].name, "a.ipynb", "Re-added should be first")
    }

    func testClear() {
        let service = makeService()
        service.add(url: URL(fileURLWithPath: "/tmp/a.ipynb"))
        service.clear()
        XCTAssertEqual(service.entries.count, 0)
    }
}

final class NotebookSettingsServiceTests: XCTestCase {

    func testDefaultSettings() {
        let service = NotebookSettingsService()
        XCTAssertEqual(service.settings.fontSize, 12)
        XCTAssertTrue(service.settings.wordWrap)
        XCTAssertTrue(service.settings.autosaveEnabled)
        XCTAssertEqual(service.settings.autosaveInterval, 30)
    }
}
