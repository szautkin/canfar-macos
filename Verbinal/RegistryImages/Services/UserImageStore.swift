// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import os
import VerbinalKit

/// The images someone added from the registry by hand, newest first.
///
/// One store for every reader — the images card, the launch form, the
/// agents' image listing — so they never disagree about the list. The
/// images are kept, not the search: a search result is a moment; the list
/// is a decision.
@Observable
@MainActor
final class UserImageStore {
    /// Nobody adds this many one at a time; a list this long is a bug or a
    /// paste, and the launch form's menu stops being usable long before.
    nonisolated static let maxImages = 200

    private(set) var images: [RegistryImage] = []

    private let persistence: DiskPersistence<[RegistryImage]>?

    /// Where each image added or removed is recorded (plan 23 C).
    private let changes: ChangeLog

    init(persistence: DiskPersistence<[RegistryImage]>? = UserImageStore.productionPersistence,
         changes: ChangeLog = .shared) {
        self.persistence = persistence
        self.changes = changes
        if case .value(let stored) = persistence?.readResult() { images = stored }
    }

    nonisolated static let productionPersistence = DiskPersistence<[RegistryImage]>(
        subdirectory: "Verbinal", fileName: "user_images.json",
        logger: Logger(subsystem: "com.codebg.Verbinal", category: "UserImages"))

    func contains(_ id: String) -> Bool { index(of: id) != nil }

    /// Adds `image` at the top; false when it is already there — an answer, not a failure.
    @discardableResult
    func add(_ image: RegistryImage) -> Bool {
        guard RegistryImage.problem(with: image.id) == nil, !contains(image.id) else { return false }
        var added = image
        added.addedAt = image.addedAt ?? Date()
        images.insert(added, at: 0)
        images = Array(images.prefix(Self.maxImages))
        save()
        changes.done("add_registry_image", "the image \(image.id) to the launch list")
        return true
    }

    /// Removes the image with this reference; false when it was not in the list.
    @discardableResult
    func remove(_ id: String) -> Bool {
        guard let index = index(of: id) else { return false }
        images.remove(at: index)
        save()
        changes.done("remove_registry_image", "the image \(id) from the launch list")
        return true
    }

    /// `catalogue` with the added images it does not list after it — the
    /// images a launch can start.
    func merged(into catalogue: [RawImage]) -> [RawImage] {
        Self.merged(images, into: catalogue)
    }

    nonisolated static func merged(_ mine: [RegistryImage], into catalogue: [RawImage]) -> [RawImage] {
        let listed = Set(catalogue.map { $0.id.lowercased() })
        return catalogue + mine.filter { !listed.contains($0.id.lowercased()) }.map(\.raw)
    }

    private func index(of id: String) -> Int? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return images.firstIndex { $0.id.lowercased() == wanted }
    }

    private func save() {
        _ = persistence?.write(images)
    }
}
