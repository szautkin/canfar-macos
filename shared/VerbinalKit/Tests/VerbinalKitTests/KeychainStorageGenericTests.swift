// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import VerbinalKit

/// Round-trip tests for the generic Keychain read/write/delete surface
/// introduced for external addons (e.g. verbinal-thought). Each test uses a
/// per-run unique service prefix so parallel / repeated runs don't collide
/// with real user Keychain data; `tearDown` deletes every account the test
/// wrote so the suite is idempotent.
///
/// NOTE: these tests exercise the real macOS Keychain and therefore require
/// a logged-in user session. When running in unattended CI without a Keychain
/// available, `writeGeneric` returns `errSecNotAvailable` or similar; rather
/// than fail, we skip the test explicitly via `XCTSkipIf` so the suite stays
/// portable. Locally they all pass.
final class KeychainStorageGenericTests: XCTestCase {

    /// Unique service string for this test instance. Every account the test
    /// writes goes under this service so `tearDown` can wipe the slate with a
    /// single enumeration. Using UUID isolates concurrent test runs.
    private var testService: String!
    /// Accounts written during a test — tracked here so `tearDown` knows what
    /// to remove even if an assertion fails mid-way.
    private var writtenAccounts: Set<String> = []

    override func setUp() {
        super.setUp()
        testService = "com.codebg.VerbinalKitTests.keychain." + UUID().uuidString
        writtenAccounts.removeAll()
    }

    override func tearDown() {
        for account in writtenAccounts {
            try? KeychainStorage.deleteGeneric(service: testService, account: account)
        }
        writtenAccounts.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Write via the public API, tracking the account so tearDown can clean
    /// up even if the test fails partway through.
    private func write(_ value: String, account: String) throws {
        try KeychainStorage.writeGeneric(value, service: testService, account: account)
        writtenAccounts.insert(account)
    }

    /// Detect hostless Keychain environments (e.g. CI without a user session).
    /// When writeGeneric throws `.osStatus(code)` for a known "not available"
    /// code, every test short-circuits with XCTSkip.
    private func skipIfKeychainUnavailable() throws {
        do {
            try write("probe", account: "keychain-availability-probe")
        } catch let error as KeychainStorage.Error {
            if case .osStatus(let code) = error,
               code == errSecNotAvailable || code == -34018 /* missing entitlement */ {
                throw XCTSkip("Keychain unavailable in this environment (OSStatus \(code))")
            }
            throw error
        }
    }

    // MARK: - Tests

    func test_write_then_read_roundtrips() throws {
        try skipIfKeychainUnavailable()
        let account = "openai-api-key"
        try write("sk-ABCDEFG.roundtrip.test", account: account)

        let roundTripped = try KeychainStorage.readGeneric(service: testService, account: account)
        XCTAssertEqual(roundTripped, "sk-ABCDEFG.roundtrip.test")
    }

    func test_write_overwrites_existing() throws {
        try skipIfKeychainUnavailable()
        let account = "openai-api-key"
        try write("first-value", account: account)
        try write("second-value-wins", account: account)

        let roundTripped = try KeychainStorage.readGeneric(service: testService, account: account)
        XCTAssertEqual(roundTripped, "second-value-wins",
                       "Second writeGeneric at the same (service, account) must replace the first.")
    }

    func test_read_missing_returns_nil() throws {
        try skipIfKeychainUnavailable()
        // Intentionally never written. Reading must return nil, not throw.
        let value = try KeychainStorage.readGeneric(
            service: testService,
            account: "never-written-\(UUID().uuidString)"
        )
        XCTAssertNil(value, "Reading a non-existent (service, account) pair returns nil — it is not an error.")
    }

    func test_delete_missing_is_noop() throws {
        try skipIfKeychainUnavailable()
        // Delete a key that was never written. The API is idempotent and
        // should not throw for `errSecItemNotFound`.
        XCTAssertNoThrow(
            try KeychainStorage.deleteGeneric(
                service: testService,
                account: "never-written-\(UUID().uuidString)"
            ),
            "deleteGeneric on a missing key must be a silent no-op."
        )
    }

    func test_delete_then_read_returns_nil() throws {
        try skipIfKeychainUnavailable()
        let account = "openai-api-key"
        try write("temporary-secret", account: account)

        // Remove from our cleanup set since we're explicitly deleting under test;
        // re-adding it after the delete would cause tearDown to delete a non-
        // existing key (harmless but untidy).
        writtenAccounts.remove(account)
        try KeychainStorage.deleteGeneric(service: testService, account: account)

        let value = try KeychainStorage.readGeneric(service: testService, account: account)
        XCTAssertNil(value, "After deleteGeneric, subsequent readGeneric returns nil.")
    }
}
