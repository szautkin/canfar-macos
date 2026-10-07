// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import SwiftUI
import XCTest
@testable import Verbinal

/// Plan 27 L, the guardrail: every screen, every Settings section and every
/// app-wide sheet, shown for real and read as an assistant reads it. Every
/// control must have a name — what VoiceOver says, and what an assistant
/// calls it by — every hand tag must be on one element only, and every
/// target must be inside its window.
@MainActor
final class EveryScreenNamedTests: XCTestCase {

    private struct Problem: CustomStringConvertible {
        let place: String
        let what: String
        var description: String { "\(place): \(what)" }
    }

    /// Hand tags each place must show, by its stable id.
    private static let expected: [String: [String]] = [
        "landing": ["home.search", "home.portal", "home.fitsViewer", "agent.pending", "activity.bar"],
        "search": ["search.tabs", "search.observation", "search.spatial", "search.target", "search.temporal",
                   "search.spectral", "search.dataTrain", "search.run", "search.reset"],
        "search.results": ["results.export", "results.columns", "results.rowsPerPage", "results.header", "results.filters"],
        "search.adql": ["adql.generate", "adql.execute"],
        "settings.agent": ["settings.agent", "settings.agent.allowExternal", "settings.agent.sessionLogs"],
        "portal.launchForm": ["portal.launch"],
    ]

    private func read(_ state: AppState, place: String, _ root: some View,
                      settle: Duration = .milliseconds(700)) async throws -> [Problem] {
        try await AXReadable.require()
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root
            .environment(state))
        window.orderFrontRegardless()
        defer { window.close() }
        let source = AXElementSource(screenName: { state.screenName(of: $0, parentScreen: $1, title: $2) })
        await source.ready()
        try await Task.sleep(for: settle)
        let snapshot = source.snapshot()
        let mine = snapshot.windows.filter { $0.number == window.windowNumber || $0.kind == .sheet }
        XCTAssertFalse(mine.isEmpty, "\(place) is listed")
        var problems: [Problem] = []
        for ref in mine {
            let elements = snapshot.elements(in: ref.index)
            let bounds = CGRect(origin: .zero, size: ref.frame.size).insetBy(dx: -1, dy: -1)
            for element in elements where element.kind.isControl && element.name == nil {
                let at = element.visible.integral
                problems.append(Problem(place: "\(place) [\(ref.screen)]",
                                        what: "unnamed \(element.kind.rawValue) at (\(Int(at.minX)), \(Int(at.minY)), \(Int(at.width))×\(Int(at.height)))"))
            }
            for element in elements where !bounds.contains(element.visible) {
                problems.append(Problem(place: "\(place) [\(ref.screen)]", what: "\(element.id) outside its window"))
            }
        }
        problems += snapshot.duplicateIDs.map { Problem(place: place, what: "hand tag \($0) on more than one element") }
        let stable = Set(snapshot.elements.filter(\.stable).map(\.id))
        problems += (Self.expected[place] ?? []).filter { !stable.contains($0) }
            .map { Problem(place: place, what: "hand tag \($0) not found") }
        return problems
    }

    private func signedIn() -> AppState {
        let state = AppState()
        state.auth.apply(username: "qa-person", userInfo: nil)
        return state
    }

    // MARK: - The screens

    func testEveryScreenHasNamesForEveryControl() async throws {
        var problems: [Problem] = []
        for mode in AppMode.allCases {
            let state = mode.requiresAuthentication ? signedIn() : AppState()
            state.currentMode = mode
            problems += try await read(state, place: mode.key, ContentView().uiWindowPlace(.main))
        }
        for tab in SearchFormModel.SearchTab.allCases where tab != .search {
            let state = AppState()
            state.currentMode = .search
            if tab == .results {
                state.searchModel.resultsModel.loadResults(
                    headers: ["Collection", "Target Name", "Instrument", "Filter"],
                    rows: [["HST", "M31", "ACS/WFC", "F814W"], ["CFHT", "M33", "MegaPrime", "r"]],
                    query: "SELECT 1", maxRec: 10)
            }
            state.searchModel.selectedTab = tab
            problems += try await read(state, place: "search.\(tab.rawValue)", ContentView().uiWindowPlace(.main))
        }
        // The launch form, a sheet of the Portal's own.
        let launching = signedIn()
        launching.currentMode = .portal
        launching.launchFormPresented = true
        problems += try await read(launching, place: "portal.launchForm", ContentView().uiWindowPlace(.main))
        XCTAssertTrue(problems.isEmpty, "\n" + problems.map(\.description).joined(separator: "\n"))
    }

    func testEverySettingsSectionHasNamesForEveryControl() async throws {
        var problems: [Problem] = []
        for section in SettingsSection.allCases {
            let state = AppState()
            state.settingsSection = section
            problems += try await read(state, place: "settings.\(section.rawValue)", SettingsView().uiWindowPlace(.settings))
        }
        XCTAssertTrue(problems.isEmpty, "\n" + problems.map(\.description).joined(separator: "\n"))
    }

    func testEveryAppWideSheetHasNamesForEveryControl() async throws {
        var problems: [Problem] = []
        for sheet in [AppState.ActiveSheet.login, .about, .export, .agentProposals, .features, .welcome, .mcpSetupWizard] {
            let state = AppState()
            state.activeSheet = sheet
            problems += try await read(state, place: "sheet.\(sheet.rawValue)", ContentView().uiWindowPlace(.main))
        }
        XCTAssertTrue(problems.isEmpty, "\n" + problems.map(\.description).joined(separator: "\n"))
    }

    /// Reading Search — the screen with the most on it — stays quick: a
    /// listing runs on the main thread while the assistant waits.
    func testReadingTheBusiestScreenIsQuick() async throws {
        try await AXReadable.require()
        let state = AppState()
        state.currentMode = .search
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().uiWindowPlace(.main)
            .environment(state))
        window.orderFrontRegardless()
        defer { window.close() }
        let source = AXElementSource(screenName: { state.screenName(of: $0, parentScreen: $1, title: $2) })
        await source.ready()
        try await Task.sleep(for: .milliseconds(700))
        // The fastest of five: a busy machine (a shared CI runner) only ever
        // adds time, so the best run is the listing's own cost.
        let clock = ContinuousClock()
        let took = (0..<5).map { _ in clock.measure { _ = source.snapshot() } }.min() ?? .zero
        XCTAssertLessThan(took, .milliseconds(150), "a snapshot of Search took \(took) at best")
    }
}
