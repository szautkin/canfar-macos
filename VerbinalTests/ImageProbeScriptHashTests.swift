// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

/// Ticket 017: the shared sha256Hex helper is a real SHA-256 (the same
/// algorithm the old CryptoKit path used, so script hashes are preserved),
/// and both probe scripts derive a stable 12-char lowercase-hex scriptHash
/// from it.
final class ImageProbeScriptHashTests: XCTestCase {

    func testKnownSHA256Vectors() {
        // Standard SHA-256 test vectors.
        XCTAssertEqual(ImageProbeScriptHash.sha256Hex(of: ""),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ImageProbeScriptHash.sha256Hex(of: "abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    private func assertScriptHash(_ hash: String, _ label: String) {
        XCTAssertEqual(hash.count, 12, "\(label) scriptHash must be 12 chars")
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) },
                      "\(label) scriptHash must be lowercase hex, got \(hash)")
    }

    func testProbeScriptHashIsStableHex() {
        let h1 = ProbeScript.scriptHash
        let h2 = ProbeScript.scriptHash
        XCTAssertEqual(h1, h2, "scriptHash must be deterministic")
        assertScriptHash(h1, "ProbeScript")
    }

    func testInspectorScriptHashIsStableHex() {
        let h1 = InspectorScript.scriptHash
        let h2 = InspectorScript.scriptHash
        XCTAssertEqual(h1, h2, "scriptHash must be deterministic")
        assertScriptHash(h1, "InspectorScript")
    }

    func testProbeAndInspectorHashesDiffer() {
        // Different script bodies -> different identities (sanity that each
        // hashes its own body, not a shared constant).
        XCTAssertNotEqual(ProbeScript.scriptHash, InspectorScript.scriptHash)
    }
}
