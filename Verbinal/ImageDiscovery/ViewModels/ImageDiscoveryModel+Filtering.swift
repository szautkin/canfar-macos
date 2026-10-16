// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// What the sheet's panes show, read from the model's state (plan 40: the
/// model had grown past its budget).
extension ImageDiscoveryModel {
    // MARK: - Filtering

    /// Image ids that satisfy the current query *and* the search
    /// text (which scopes by image label / id substring on the
    /// right pane).
    var filteredImageIDs: [String] {
        let cached = allKnownImages.compactMap { img -> String? in
            // Only successful manifests can satisfy a non-empty
            // query — failures and pending have no manifest to match.
            if case .discovered(let m) = rowStates[img.id] {
                return query.isEmpty || query.matches(m) ? img.id : nil
            }
            // For empty query, include everything we know about
            // (running / failed / never-discovered all show up so
            // the user can see progress).
            return query.isEmpty ? img.id : nil
        }
        // Apply image-scoped search on top.
        let searched: [String]
        if imageSearchText.isEmpty {
            searched = cached
        } else {
            let needle = imageSearchText.lowercased()
            searched = cached.filter { id in
                id.lowercased().contains(needle) ||
                allKnownImages.first(where: { $0.id == id })?.label.lowercased().contains(needle) == true
            }
        }
        // Session-type filter. Unknown-type (cache-only) images are never
        // hidden — they bucket under "All" so a Skaha-catalogue outage
        // doesn't make them vanish when a specific type is selected.
        guard let type = typeFilter else { return searched }
        return searched.filter { id in
            guard let img = allKnownImages.first(where: { $0.id == id }) else { return false }
            return img.types.isEmpty || img.types.contains(type)
        }
    }

    /// Session types present across the catalogue, in canonical UI order
    /// (then any extras alphabetically). Drives the type filter control.
    var availableTypes: [String] {
        let present = Set(allKnownImages.flatMap { $0.types })
        let canonical = ["notebook", "desktop", "carta", "headless", "contributed", "firefly", "desktop-app"]
        let ordered = canonical.filter { present.contains($0) }
        let extras = present.subtracting(canonical).sorted()
        return ordered + extras
    }

    /// Every successfully-discovered manifest in row state. Used by
    /// `availableValues(for:)` and the chips/filter logic that
    /// needs to look at actual package contents, not just the
    /// catalogue's all-known values.
    var allDiscoveredManifests: [ImageManifest] {
        rowStates.values.compactMap {
            if case .discovered(let m) = $0 { return m } else { return nil }
        }
    }

    /// Set of values for `category` that, if added to the query,
    /// would still yield at least one matching manifest given the
    /// CURRENT settings of every OTHER category. The left pane
    /// uses this to disable checkboxes whose values are guaranteed
    /// to make the result empty — e.g. once `OS = centos` is
    /// ticked, `Python = numpy` should grey out unless at least
    /// one centos manifest has numpy.
    func availableValues(for category: PackageQuery.Category) -> Set<String> {
        let scoped = query.dropping(category)
        var available: Set<String> = []
        for m in allDiscoveredManifests where scoped.matches(m) {
            switch category {
            case .osFamily:
                if m.osFamily != "unknown" { available.insert(m.osFamily) }
            case .osVersion:
                if m.osVersion != "unknown" { available.insert(m.osVersion) }
            case .python:       available.formUnion(m.pythonPackages.map(\.name))
            case .r:            available.formUnion(m.rPackages.map(\.name))
            case .dpkg:         available.formUnion(m.dpkgPackages.map(\.name))
            case .rpm:          available.formUnion(m.rpmPackages.map(\.name))
            case .apk:          available.formUnion(m.apkPackages.map(\.name))
            case .capabilities: available.formUnion(m.capabilities)
            }
        }
        return available
    }

    /// Project-grouped view of `filteredImageIDs` for the right pane
    /// `Section` headers.
    var filteredImagesByProject: [(project: String, images: [ParsedImage])] {
        let allowed = Set(filteredImageIDs)
        let group = Dictionary(grouping: allKnownImages.filter { allowed.contains($0.id) },
                               by: { $0.project })
        return group
            .map { (project: $0.key, images: $0.value.sorted { $0.label < $1.label }) }
            .sorted { $0.project < $1.project }
    }
}
