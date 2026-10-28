// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Code pasted into the Run code box: what Python and Bash would stop at,
/// named, and made plain.
final class PastedCodeTests: XCTestCase {

    func testThePersonsRunsAreFixed() {
        XCTAssertEqual(PastedCode.fixed("print(“Hello world”);"), #"print("Hello world");"#)
        XCTAssertEqual(PastedCode.fixed("print(‘Hello world’);"), "print('Hello world');")
        XCTAssertEqual(PastedCode.kinds(in: "print(“Hello world”);"), [.quotes])
    }

    func testEachKindIsNamedOnceInOrder() {
        let pasted = "\u{FEFF}ls\u{00A0}—all | grep “x” … \u{2028}echo ‘done’ − 1\u{200B}"
        XCTAssertEqual(PastedCode.kinds(in: pasted), [.quotes, .dashes, .ellipses, .spaces, .invisible, .lineSeparators])
        XCTAssertEqual(PastedCode.fixed(pasted), "ls --all | grep \"x\" ... \necho 'done' - 1")
    }

    func testFrenchQuotesAndTheirSpacesGoPlain() {
        XCTAssertEqual(PastedCode.fixed("print(«\u{202F}Bonjour\u{202F}»)"), #"print(" Bonjour ")"#)
    }

    func testPlainCodeAndMeantUnicodeAreLeftAlone() {
        let code = """
        # µJy, é, 🧑‍🚀 — none of it pasted by mistake
        print("flux in µJy:", 3.2e-3, 'café')
        """
        XCTAssertEqual(PastedCode.kinds(in: "print('ok')\n\tx = a - b  # --flag"), [])
        XCTAssertEqual(PastedCode.fixed("print('ok')\n\tx = a - b  # --flag"), "print('ok')\n\tx = a - b  # --flag")
        XCTAssertEqual(PastedCode.kinds(in: code), [.dashes], "only the em dash: µ, é and the emoji's joiner stay")
        XCTAssertTrue(PastedCode.fixed(code).contains("🧑‍🚀"))
        XCTAssertTrue(PastedCode.fixed(code).contains("µJy"))
    }

    func testFixingTwiceChangesNothingMore() {
        let once = PastedCode.fixed("a\u{00A0}=\u{00A0}“b” — c…")
        XCTAssertEqual(PastedCode.fixed(once), once)
        XCTAssertEqual(PastedCode.kinds(in: once), [])
    }
}
