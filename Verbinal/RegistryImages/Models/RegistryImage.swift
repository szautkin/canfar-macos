// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// An image as the container registry describes it: its reference and the
/// session types its labels name.
///
/// The platform's catalogue is curated — Skaha lists what it will launch.
/// The registry behind it holds far more, and someone who knows the image
/// they want (a colleague's build, a tag Skaha has not picked up) reaches
/// it only by searching for it and adding it. One type for both moments:
/// `addedAt` is nil for a search result, set once it is in their list.
struct RegistryImage: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// `host/project/name:tag`, exactly as a launch takes it.
    let id: String
    /// The session types the registry's labels declare.
    let types: [String]
    var addedAt: Date?

    /// The labels that name a session type — all that mean anything to a
    /// launch, and what the images card and the launch form filter by.
    static let sessionTypeLabels = ["notebook", "desktop", "desktop-app", "carta", "firefly", "headless", "contributed"]

    init(id: String, types: [String], addedAt: Date? = nil) {
        self.id = id
        self.types = types
        self.addedAt = addedAt
    }

    /// An image from a reference and whatever labels it carries. Labels
    /// that name no session type are dropped: an image labelled "gpu" is
    /// not launchable as a "gpu" session.
    init(id: String, labels: [String], addedAt: Date? = nil) {
        var types: [String] = []
        for label in labels.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
        where Self.sessionTypeLabels.contains(label) && !types.contains(label) {
            types.append(label)
        }
        self.init(id: id, types: types, addedAt: addedAt)
    }

    /// Whether the launch form's Standard tab can offer it: only by a
    /// session type its labels declare. One without (QA L16:
    /// `espsrc/astroml-pandas-george`) is launched from Advanced, with a type.
    var isOfferedOnStandard: Bool { !types.isEmpty }

    /// The project — `host/PROJECT/name:tag` — as the catalogue's images have it.
    var project: String { ImageParser.parse(raw).project }

    /// As the platform's catalogue lists an image.
    var raw: RawImage { RawImage(id: id, types: types) }

    /// A reference or registry host as typed or pasted, made one: without
    /// whitespace or a web scheme, neither of which a reference can have and
    /// both of which a copy from a browser brings.
    static func normalized(_ text: String) -> String {
        let bare = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard let scheme = bare.range(of: "://") else { return bare }
        return String(bare[scheme.upperBound...])
    }

    /// The problem with `reference` as an image to add, or nil when it is
    /// one: it needs a tag, since a bare name would be kept, offered, and
    /// refused by the platform at launch.
    static func problem(with reference: String) -> String? {
        if reference.isEmpty { return "an image reference is required" }
        let name = reference.split(separator: "/").last.map(String.init) ?? reference
        return name.contains(":") ? nil : "'\(reference)' has no tag — an image reference is host/project/name:tag"
    }
}
