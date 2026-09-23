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
    func openFile(url: URL) async -> Document
    func closeTab(at index: Int)
}

extension ViewerTabHosting {
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
