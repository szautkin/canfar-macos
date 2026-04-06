// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class PythonHighlighterTests: XCTestCase {

    func testCommentToken() {
        let tokens = PythonHighlighter.tokens(in: "# hello world")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .comment)
    }

    func testDoubleQuoteString() {
        let tokens = PythonHighlighter.tokens(in: "x = \"hello\"")
        let strings = tokens.filter { $0.kind == .string }
        XCTAssertEqual(strings.count, 1)
    }

    func testSingleQuoteString() {
        let tokens = PythonHighlighter.tokens(in: "x = 'hello'")
        let strings = tokens.filter { $0.kind == .string }
        XCTAssertEqual(strings.count, 1)
    }

    func testTripleQuoteString() {
        let tokens = PythonHighlighter.tokens(in: "\"\"\"docstring\"\"\"")
        let strings = tokens.filter { $0.kind == .string }
        XCTAssertEqual(strings.count, 1)
    }

    func testKeyword() {
        let tokens = PythonHighlighter.tokens(in: "def foo():")
        let keywords = tokens.filter { $0.kind == .keyword }
        XCTAssertEqual(keywords.count, 1)
    }

    func testBuiltin() {
        let tokens = PythonHighlighter.tokens(in: "print(x)")
        let builtins = tokens.filter { $0.kind == .builtIn }
        XCTAssertEqual(builtins.count, 1)
    }

    func testNumber() {
        let tokens = PythonHighlighter.tokens(in: "x = 42")
        let numbers = tokens.filter { $0.kind == .number }
        XCTAssertEqual(numbers.count, 1)
    }

    func testHexNumber() {
        let tokens = PythonHighlighter.tokens(in: "x = 0xFF")
        let numbers = tokens.filter { $0.kind == .number }
        XCTAssertEqual(numbers.count, 1)
    }

    func testDecorator() {
        let tokens = PythonHighlighter.tokens(in: "@staticmethod")
        let decorators = tokens.filter { $0.kind == .decorator }
        XCTAssertEqual(decorators.count, 1)
    }

    func testKeywordInStringIsString() {
        // "def" inside a string should be .string, not .keyword
        let tokens = PythonHighlighter.tokens(in: "x = \"def\"")
        let keywords = tokens.filter { $0.kind == .keyword }
        XCTAssertEqual(keywords.count, 0, "Keyword inside string should not be tokenized")
    }

    func testMultipleTokenTypes() {
        let source = "import numpy as np  # math library"
        let tokens = PythonHighlighter.tokens(in: source)
        let keywords = tokens.filter { $0.kind == .keyword }
        let comments = tokens.filter { $0.kind == .comment }
        XCTAssertTrue(keywords.count >= 2, "Should have 'import' and 'as' keywords")
        XCTAssertEqual(comments.count, 1)
    }

    func testEmptyString() {
        let tokens = PythonHighlighter.tokens(in: "")
        XCTAssertEqual(tokens.count, 0)
    }
}
