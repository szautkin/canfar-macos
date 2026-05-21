// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Search criteria for finding images that match a set of required
/// packages. v1 is name-only, intersection-only — an image matches
/// when its manifest contains every name in every populated
/// constraint set.
///
/// Version-range operators (`>=`, `~=`, `==1.2.x`) are out of scope
/// for v1; the brief in `describe_app` is explicit. v2 can extend
/// this struct with a `versionConstraint: VersionConstraint?` per
/// entry without breaking the v1 callers.
struct PackageQuery: Equatable, Sendable {

    /// `["ubuntu", "almalinux"]` etc. Empty = no filter.
    var osFamilies: Set<String> = []

    /// Version strings to match within the chosen family, e.g.
    /// `["22.04"]`. Matches against `osVersion`.
    var osVersions: Set<String> = []

    /// dpkg / apt package names that must be present.
    var dpkg: Set<String> = []

    /// rpm package names that must be present.
    var rpm: Set<String> = []

    /// apk package names that must be present.
    var apk: Set<String> = []

    /// Python package names (any conda env or system pip) that must
    /// be present. Intersection ignores env — a hit in conda env
    /// `astroml` counts the same as a hit in system pip.
    var python: Set<String> = []

    /// R package names that must be present.
    var r: Set<String> = []

    /// Behavioural capability flags that must all be present in
    /// the manifest's `capabilities`. Keys come from
    /// `ImageManifest.Capability` (e.g. `"fitsio"`, `"gpu"`,
    /// `"photutils-iterative-psf"`). Lets agents filter on
    /// behaviours that pure package-name matching can't express —
    /// e.g. "image has fitsio AND it actually imports" or
    /// "image has GPU runtime wired up".
    var capabilities: Set<String> = []

    /// True when every populated constraint must be satisfied
    /// (intersection). v1 only supports `true`; the field is here
    /// for forward compatibility. Setting it to `false` is treated
    /// as `true` in v1.
    var requireAll: Bool = true

    /// True when no constraint is set — the caller wants every
    /// known image. The UI's right pane uses this to render the
    /// full catalogue when no checkbox is ticked.
    var isEmpty: Bool {
        osFamilies.isEmpty &&
        osVersions.isEmpty &&
        dpkg.isEmpty &&
        rpm.isEmpty &&
        apk.isEmpty &&
        python.isEmpty &&
        r.isEmpty &&
        capabilities.isEmpty
    }

    /// Filter category — used by the UI's "available values"
    /// computation to ask "which values would yield ≥1 result if
    /// added to a query that's missing my own category's filter?".
    /// Lets the left pane disable checkboxes whose value can't
    /// produce a match given the rest of the active filters.
    enum Category: Hashable, Sendable {
        case osFamily, osVersion, python, r, dpkg, rpm, apk, capabilities
    }

    /// Return a copy with the given category's filter cleared.
    /// Used to evaluate "could this checkbox still match?" without
    /// mutating the live query.
    func dropping(_ category: Category) -> PackageQuery {
        var copy = self
        switch category {
        case .osFamily:     copy.osFamilies.removeAll()
        case .osVersion:    copy.osVersions.removeAll()
        case .python:       copy.python.removeAll()
        case .r:            copy.r.removeAll()
        case .dpkg:         copy.dpkg.removeAll()
        case .rpm:          copy.rpm.removeAll()
        case .apk:          copy.apk.removeAll()
        case .capabilities: copy.capabilities.removeAll()
        }
        return copy
    }

    /// Score a manifest's coverage of this query's constraints.
    /// Returns a fraction `0.0…1.0` for the proportion of
    /// individual constraints satisfied, plus the list of
    /// unsatisfied constraint identifiers.
    ///
    /// **Constraint counting.** Each package name in `dpkg` /
    /// `rpm` / `python` / etc. counts as one constraint; the OS
    /// family / version constraints each count as one. `score`
    /// is `satisfied / total`, where `total` is the sum of all
    /// names + the OS constraints when populated.
    ///
    /// **Why this exists.** 2026-05-15 QA finding: asking for
    /// `[astropy, scipy, astroquery, numpy, fitsio, python3]`
    /// returned 0 strict matches because no single image had all
    /// six — even though four images had three or more. Pure
    /// AND-match left the agent with no actionable next step.
    /// Partial scoring surfaces those near-miss images with a
    /// `score` and a `missing` list so the agent can decide
    /// between "use this image and `pip install` the gap" or
    /// "loosen the query."
    ///
    /// Returns `(1.0, [])` for an empty query (degenerate case;
    /// every manifest trivially satisfies "no constraints").
    func score(_ manifest: ImageManifest) -> (score: Double, missing: [String]) {
        var satisfied = 0
        var total = 0
        var missing: [String] = []

        if !osFamilies.isEmpty {
            total += 1
            if osFamilies.contains(manifest.osFamily) {
                satisfied += 1
            } else {
                missing.append("osFamily")
            }
        }
        if !osVersions.isEmpty {
            total += 1
            if osVersions.contains(manifest.osVersion) {
                satisfied += 1
            } else {
                missing.append("osVersion")
            }
        }

        func scoreSet(_ requested: Set<String>, _ available: Set<String>, label: String) {
            total += requested.count
            for name in requested {
                if available.contains(name) {
                    satisfied += 1
                } else {
                    missing.append("\(label):\(name)")
                }
            }
        }

        scoreSet(dpkg,         Set(manifest.dpkgPackages.map(\.name)),   label: "dpkg")
        scoreSet(rpm,          Set(manifest.rpmPackages.map(\.name)),    label: "rpm")
        scoreSet(apk,          Set(manifest.apkPackages.map(\.name)),    label: "apk")
        scoreSet(python,       Set(manifest.pythonPackages.map(\.name)), label: "python")
        scoreSet(r,            Set(manifest.rPackages.map(\.name)),      label: "r")
        scoreSet(capabilities, Set(manifest.capabilities),               label: "capability")

        if total == 0 {
            return (1.0, [])
        }
        return (Double(satisfied) / Double(total), missing)
    }

    /// Test whether a manifest satisfies all constraints in this
    /// query. The cache uses this to filter its in-memory snapshot
    /// without iterating the disk store.
    func matches(_ manifest: ImageManifest) -> Bool {
        if !osFamilies.isEmpty && !osFamilies.contains(manifest.osFamily) {
            return false
        }
        if !osVersions.isEmpty && !osVersions.contains(manifest.osVersion) {
            return false
        }
        if !dpkg.isEmpty {
            let names = Set(manifest.dpkgPackages.map(\.name))
            if !dpkg.isSubset(of: names) { return false }
        }
        if !rpm.isEmpty {
            let names = Set(manifest.rpmPackages.map(\.name))
            if !rpm.isSubset(of: names) { return false }
        }
        if !apk.isEmpty {
            let names = Set(manifest.apkPackages.map(\.name))
            if !apk.isSubset(of: names) { return false }
        }
        if !python.isEmpty {
            let names = Set(manifest.pythonPackages.map(\.name))
            if !python.isSubset(of: names) { return false }
        }
        if !capabilities.isEmpty {
            let have = Set(manifest.capabilities)
            if !capabilities.isSubset(of: have) { return false }
        }
        if !r.isEmpty {
            let names = Set(manifest.rPackages.map(\.name))
            if !r.isSubset(of: names) { return false }
        }
        return true
    }
}

/// Snapshot of every distinct package name seen across all cached
/// manifests, grouped by source. Drives the LEFT pane of the
/// discovery sheet so the user only sees real choices.
struct AllPackages: Equatable, Sendable {
    var osFamilies: Set<String> = []
    /// `family → versions` so the UI can collapse "ubuntu 22.04 / 20.04"
    /// under one section header.
    var osVersionsByFamily: [String: Set<String>] = [:]
    var dpkg: Set<String> = []
    var rpm: Set<String> = []
    var apk: Set<String> = []
    var python: Set<String> = []
    var r: Set<String> = []

    var isEmpty: Bool {
        osFamilies.isEmpty &&
        osVersionsByFamily.isEmpty &&
        dpkg.isEmpty &&
        rpm.isEmpty &&
        apk.isEmpty &&
        python.isEmpty &&
        r.isEmpty
    }
}
