// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What the coordinator decides from a name or a list alone — a probe job's
/// name, a stub list — kept apart from the pipeline (plan 40: the file had
/// grown past its budget).
extension ImageDiscoveryCoordinator {
    /// A "stub" manifest is one a failed probe wrote as a
    /// placeholder: no packages of any kind, and a `probeNotes`
    /// field describing the failure. Real successful probes always
    /// have *something* (even Alpine's minimal image returns a
    /// dozen apk entries) and don't set `probeNotes`. Used by
    /// `fetchManifestIfPresent` to refuse to cache failure
    /// placeholders, and intended to be cheap (no I/O) so the
    /// recovery path stays a single-VOSpace-read in the happy case.
    static func isStubManifest(_ m: ImageManifest) -> Bool {
        let hasPackages = !(m.dpkgPackages.isEmpty
                            && m.rpmPackages.isEmpty
                            && m.apkPackages.isEmpty
                            && m.pythonPackages.isEmpty
                            && m.rPackages.isEmpty
                            && m.condaEnvs.isEmpty)
        if hasPackages { return false }
        // Empty-everything is the stub shape; require a probeNotes
        // tag too so a hypothetical legitimate "scratch" image with
        // truly zero packages doesn't get mistaken for a stub.
        return (m.probeNotes ?? "").isEmpty == false
    }

    /// Build a Skaha session-name that's safe for K8s DNS-1123
    /// label rules (≤63 chars, lowercase alphanumerics + hyphens,
    /// no leading/trailing hyphen, no consecutive hyphens).
    ///
    /// Old builder produced names like
    /// `verbinal-inspect-images-canfar-net-cadc-carta-psrecord-5--abcd1234`
    /// (66 chars, double hyphen mid-name) — the length tripped K8s
    /// admission webhooks (label-value cap is 63), and the
    /// trailing chop landed inside `5.1.0` leaving a stray `5-` that
    /// Skaha's Java regex parser is known to choke on. Both fits
    /// the "K8s race after submit" pattern we kept seeing.
    ///
    /// The new builder reserves the prefix + UUID up front, slices
    /// the image-derived middle to whatever's left, then collapses
    /// `_`/`.`/space → `-`, drops consecutive hyphens, and trims
    /// edge hyphens. Worst case: `vp-<54chars>-<8uuid>` = 64 — but
    /// the slice already caps the middle at 52, so we're at most 63.
    static func makeJobName(prefix: String, imageID: String) -> String {
        let uuid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        // K8s label cap (63) minus prefix, separators, uuid.
        let budget = 63 - prefix.count - 1 - uuid.count - 1   // "<prefix>-<middle>-<uuid>"
        let safe = ImageManifest.sanitize(imageID: imageID).lowercased()
        var middle = String(safe.prefix(max(0, budget)))
        // Replace any non-DNS-1123 char with hyphen, then collapse
        // runs of hyphens, then trim leading/trailing hyphens.
        middle = middle.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" { return ch }
            return "-"
        }.reduce(into: "") { acc, ch in
            if ch == "-" && acc.last == "-" { return }
            acc.append(ch)
        }
        while middle.hasPrefix("-") { middle.removeFirst() }
        while middle.hasSuffix("-") { middle.removeLast() }
        // If trimming somehow emptied the middle (degenerate input),
        // fall back to the uuid alone so we still produce a valid name.
        if middle.isEmpty { return "\(prefix)-\(uuid)" }
        return "\(prefix)-\(middle)-\(uuid)"
    }
}
