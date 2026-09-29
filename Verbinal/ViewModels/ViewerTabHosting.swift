// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A document a viewer tab can hold (FITS image, spectral cube).
@MainActor
protocol ViewerDocument: AnyObject {
    /// Noun for the generic failure message ("FITS file", "cube").
    static var documentKind: String { get }
    var loadError: String? { get }
    /// True once the open produced data the viewer can show.
    var isLoaded: Bool { get }
    var isLoading: Bool { get }
    /// The file this tab shows (set when the open starts).
    var fileURL: URL? { get }
}

extension ViewerDocument {
    /// Why the last open left no usable document, or nil when it loaded.
    var loadFailure: String? {
        if let loadError, !loadError.isEmpty { return loadError }
        return isLoaded ? nil : "\(Self.documentKind) did not load"
    }
}

/// Multi-document host shared by the FITS and Cube viewers. Conformers
/// supply the tab primitives; the open/rollback policy lives here once.
@MainActor
protocol ViewerTabHosting: AnyObject {
    associatedtype Document: ViewerDocument
    var tabs: [Document] { get }
    var activeTabIndex: Int { get set }
    /// Opens `url` in a new, focused tab and waits for the load.
    func openNewTab(url: URL) async -> Document
    func closeTab(at index: Int)
}

extension ViewerTabHosting {
    /// Opens `url` — unless a tab already shows it, loaded or still
    /// loading: that tab is focused (and awaited) instead of a duplicate
    /// being added. A tab whose open failed does not count; the file is
    /// opened afresh. Once it has loaded, the empty tab a viewer keeps
    /// while nothing is open goes: it was a ghost beside the cube (QA N6).
    @discardableResult
    func openFile(url: URL) async -> Document {
        guard let existing = tab(showing: url) else {
            let opened = await openNewTab(url: url)
            if opened.isLoaded { closeEmptyTabs(besides: opened) }
            return opened
        }
        if let index = tabs.firstIndex(where: { $0 === existing }) { activeTabIndex = index }
        while existing.isLoading, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return existing
    }

    /// One path per tab, index-aligned with `activeTabIndex` (a tab whose
    /// load failed still has its path; a tab never opened has "").
    var tabPaths: [String] { tabs.map { $0.fileURL?.path ?? "" } }

    /// The tab showing `url`, when it loaded or is loading.
    func tab(showing url: URL) -> Document? {
        let wanted = FileIdentity.key(url)
        return tabs.first { tab in
            guard let open = tab.fileURL, FileIdentity.key(open) == wanted else { return false }
            return tab.isLoaded || tab.isLoading
        }
    }

    /// Closes the tabs nothing was ever opened in, keeping `kept` focused.
    private func closeEmptyTabs(besides kept: Document) {
        for tab in tabs where tab !== kept && tab.fileURL == nil && !tab.isLoading {
            closeTab(tab)
        }
        if let index = tabs.firstIndex(where: { $0 === kept }) { activeTabIndex = index }
    }

    func closeTab(_ tab: Document) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        closeTab(at: index)
    }

    /// Agent path: like ``openFile(url:)``, but a failed load is rolled
    /// back — the new tab is discarded and focus returns to the tab that
    /// had it — so a dead document never stays active. The UI calls
    /// ``openFile(url:)`` directly and keeps the failed tab for its error
    /// and Retry.
    /// - Returns: the failure reason, or `nil` when the document loaded.
    func openFileDiscardingFailure(url: URL) async -> String? {
        let previous = focusedTab
        let tab = await openFile(url: url)
        guard let failure = tab.loadFailure else { return nil }
        // Only hand focus back if nobody moved it while the load ran.
        let stillFocused = focusedTab === tab
        closeTab(tab)
        if stillFocused, let previous,
           let index = tabs.firstIndex(where: { $0 === previous }) {
            activeTabIndex = index
        }
        return failure
    }

    private var focusedTab: Document? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }
}
