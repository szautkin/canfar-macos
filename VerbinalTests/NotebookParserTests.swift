// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

final class NotebookParserTests: XCTestCase {

    private let sampleNotebook = """
    {
        "nbformat": 4,
        "nbformat_minor": 5,
        "metadata": {
            "kernelspec": {
                "name": "python3",
                "display_name": "Python 3",
                "language": "python"
            }
        },
        "cells": [
            {
                "cell_type": "code",
                "source": ["print('hello')\\n"],
                "metadata": {},
                "outputs": [],
                "execution_count": 1,
                "id": "abc12345"
            },
            {
                "cell_type": "markdown",
                "source": ["# Title\\n", "Some text"],
                "metadata": {},
                "id": "def67890"
            }
        ]
    }
    """

    func testParseNotebook() throws {
        let data = Data(sampleNotebook.utf8)
        let doc = try NotebookParser.parse(data)

        XCTAssertEqual(doc.nbformat, 4)
        XCTAssertEqual(doc.cells.count, 2)
        XCTAssertEqual(doc.cells[0].cellType, "code")
        XCTAssertEqual(doc.cells[1].cellType, "markdown")
    }

    func testParseCellSource() throws {
        let data = Data(sampleNotebook.utf8)
        let doc = try NotebookParser.parse(data)

        XCTAssertEqual(doc.cells[0].sourceText, "print('hello')\n")
        XCTAssertEqual(doc.cells[1].sourceText, "# Title\nSome text")
    }

    func testParseCellIds() throws {
        let data = Data(sampleNotebook.utf8)
        let doc = try NotebookParser.parse(data)

        XCTAssertEqual(doc.cells[0].id, "abc12345")
        XCTAssertEqual(doc.cells[1].id, "def67890")
    }

    func testParseExecutionCount() throws {
        let data = Data(sampleNotebook.utf8)
        let doc = try NotebookParser.parse(data)

        XCTAssertEqual(doc.cells[0].executionCount, 1)
        XCTAssertNil(doc.cells[1].executionCount)
    }

    func testSerializeRoundTrip() throws {
        let data = Data(sampleNotebook.utf8)
        let doc = try NotebookParser.parse(data)
        let serialized = try NotebookParser.serialize(doc)
        let doc2 = try NotebookParser.parse(serialized)

        XCTAssertEqual(doc2.cells.count, doc.cells.count)
        XCTAssertEqual(doc2.cells[0].sourceText, doc.cells[0].sourceText)
        XCTAssertEqual(doc2.cells[1].sourceText, doc.cells[1].sourceText)
    }

    func testCreateEmpty() {
        let doc = NotebookParser.createEmpty()
        XCTAssertEqual(doc.nbformat, 4)
        XCTAssertEqual(doc.cells.count, 1)
        XCTAssertEqual(doc.cells[0].cellType, "code")
        XCTAssertNotNil(doc.cells[0].id)
    }

    func testGenerateCellId() {
        let id = NotebookParser.generateCellId()
        XCTAssertEqual(id.count, 8, "Cell ID should be 8 hex chars")
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit }, "Cell ID should be hex only")
    }

    func testSplitSourceLines() {
        let lines = NotebookParser.splitSourceLines("line1\nline2\nline3")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "line1\n")
        XCTAssertEqual(lines[1], "line2\n")
        XCTAssertEqual(lines[2], "line3")
    }

    func testSplitSourceLinesEmpty() {
        let lines = NotebookParser.splitSourceLines("")
        XCTAssertEqual(lines.count, 0)
    }

    func testFromPythonFile() {
        let data = Data("import numpy\nprint('hi')".utf8)
        let doc = NotebookParser.fromPythonFile(data)
        XCTAssertEqual(doc.cells.count, 1)
        XCTAssertEqual(doc.cells[0].cellType, "code")
        XCTAssertTrue(doc.cells[0].sourceText.contains("import numpy"))
    }

    func testFromMarkdownFile() {
        let data = Data("# Hello\nWorld".utf8)
        let doc = NotebookParser.fromMarkdownFile(data)
        XCTAssertEqual(doc.cells.count, 1)
        XCTAssertEqual(doc.cells[0].cellType, "markdown")
        XCTAssertTrue(doc.cells[0].sourceText.contains("# Hello"))
    }

    func testNormalizeMissingCellIds() throws {
        let json = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
            {"cell_type":"code","source":[],"metadata":{},"outputs":[]}
        ]}
        """
        let doc = try NotebookParser.parse(Data(json.utf8))
        XCTAssertNotNil(doc.cells[0].id, "Missing cell ID should be auto-generated")
        XCTAssertEqual(doc.cells[0].id!.count, 8)
    }

    func testMarkdownCellNoOutputsOnSerialize() throws {
        var doc = NotebookParser.createEmpty()
        doc.cells = [
            NotebookCellData(cellType: "markdown", source: ["# Hi"], outputs: [CellOutputData(outputType: "stream")])
        ]
        let serialized = try NotebookParser.serialize(doc)
        let reparsed = try NotebookParser.parse(serialized)
        XCTAssertNil(reparsed.cells[0].outputs, "Markdown cells should have nil outputs after serialize")
    }
}
