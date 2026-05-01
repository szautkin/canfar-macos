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
        r.isEmpty
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
