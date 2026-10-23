// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What a screen is asked to do when it shows (plan 38): open a file, search
/// at a position, load a search — one at a time, taken by the screen it is
/// for. Each screen still reads its own name for it.
extension AppState {
    /// Pending sky coordinates from FITS viewer crosshair → Search tab.
    /// Includes a unique `id` so `.task(id:)` always re-fires, even if the
    /// same sky position is searched twice in a row.
    struct PendingCoordinate: Equatable {
        let id = UUID()
        let ra: Double
        let dec: Double
    }

    #if os(macOS)
    /// Pending saved-query / recent-search load → Search module (the
    /// `load_saved_search` agent tool's bridge, mirroring
    /// `pendingSearchCoordinate`): a recent search restores its full form
    /// snapshot; a saved query lands its ADQL in the editor tab. The `id`
    /// keeps `.task(id:)` re-firing on repeat loads of the same target.
    struct PendingSearchLoad: Equatable {
        let id = UUID()
        enum Kind: Equatable {
            case snapshot(SearchFormSnapshot)
            case adql(String)
        }
        let kind: Kind
    }
    #endif

    enum AppAction {
        case openFITS(url: URL)
        case openCube(url: URL)
        case searchCoordinates(ra: Double, dec: Double)
    }

    func dispatch(_ action: AppAction) {
        switch action {
        case .openFITS(let url):
            pendingFITSURL = url
            navigateTo(.fitsViewer)
        case .openCube(let url):
            pendingCubeURL = url
            navigateTo(.cubeViewer)
        case .searchCoordinates(let ra, let dec):
            pendingSearchCoordinate = PendingCoordinate(ra: ra, dec: dec)
            navigateTo(.search)
        }
    }

    enum HandOff: Equatable {
        case openFITS(URL)
        case openCube(URL)
        case searchAt(PendingCoordinate)
        #if os(macOS)
        case loadSearch(PendingSearchLoad)
        #endif
    }

    /// A FITS file for the FITS Viewer.
    var pendingFITSURL: URL? {
        get { if case .openFITS(let url) = handOff { url } else { nil } }
        set { take(newValue.map(HandOff.openFITS), replacing: { if case .openFITS = $0 { true } else { false } }) }
    }

    /// A cube for the Cube Viewer — its own tile, separate from the FITS viewer.
    var pendingCubeURL: URL? {
        get { if case .openCube(let url) = handOff { url } else { nil } }
        set { take(newValue.map(HandOff.openCube), replacing: { if case .openCube = $0 { true } else { false } }) }
    }

    /// Sky coordinates from the FITS viewer's crosshair, for Search.
    var pendingSearchCoordinate: PendingCoordinate? {
        get { if case .searchAt(let coordinate) = handOff { coordinate } else { nil } }
        set { take(newValue.map(HandOff.searchAt), replacing: { if case .searchAt = $0 { true } else { false } }) }
    }

    #if os(macOS)
    /// A saved query or recent search to load into Search.
    var pendingSearchLoad: PendingSearchLoad? {
        get { if case .loadSearch(let load) = handOff { load } else { nil } }
        set { take(newValue.map(HandOff.loadSearch), replacing: { if case .loadSearch = $0 { true } else { false } }) }
    }
    #endif

    /// A new hand-off replaces whatever waits; taking one (nil) clears it
    /// only when it is still that kind — a newer one of another kind stays.
    private func take(_ new: HandOff?, replacing isSameKind: (HandOff) -> Bool) {
        if let new {
            handOff = new
        } else if let waiting = handOff, isSameKind(waiting) {
            handOff = nil
        }
    }
}
