// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// Searching the registry and keeping what is found. Nothing happens until
/// Search: the person who opened it already knows roughly what they want.
@Observable
@MainActor
final class RegistrySearchModel {
    typealias Search = @MainActor (String) async throws(RegistrySearchError) -> [RegistryImage]

    enum Phase: Equatable {
        case idle
        case searching
        case found
        case failed(String)
    }

    var query = ""
    private(set) var results: [RegistryImage] = []
    private(set) var phase: Phase = .idle
    /// The query the results answer, not the one being typed.
    private(set) var searched = ""

    let store: UserImageStore
    private let search: Search

    init(store: UserImageStore, search: @escaping Search) {
        self.store = store
        self.search = search
    }

    var canSearch: Bool {
        phase != .searching && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func run() async {
        guard canSearch else { return }
        let asked = query.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .searching
        results = []
        do {
            results = try await search(asked)
            searched = asked
            phase = .found
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func isAdded(_ image: RegistryImage) -> Bool { store.contains(image.id) }

    func add(_ image: RegistryImage) { store.add(image) }

    func remove(_ image: RegistryImage) { store.remove(image.id) }

    /// What the types of `image` mean for a launch.
    static func typesLine(_ image: RegistryImage) -> String {
        image.types.isEmpty
            ? String(localized: "No session type — launch it from the Advanced tab")
            : image.types.joined(separator: ", ")
    }
}
