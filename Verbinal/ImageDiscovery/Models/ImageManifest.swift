// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Structured snapshot of what's installed inside a Skaha container
/// image. Produced by the in-container probe script (`ProbeScript`),
/// parsed by `ManifestParser`, persisted by the cache.
///
/// `schemaVersion` is part of the contract so a probe script update
/// (which lives on the user's VOSpace as probe-<hash>.sh) can ship
/// new fields without breaking caches written by older versions; the
/// parser tolerates missing optional fields and the cache stores the
/// parsed shape, not the raw JSON.
struct ImageManifest: Codable, Equatable, Sendable {
    /// Bumped when the JSON contract changes. Parser maps older
    /// versions forward; the cache layer can throw on a version it
    /// doesn't understand and treat the manifest as missing.
    let schemaVersion: Int

    /// Full registry-qualified image identifier as the catalog returns
    /// it, e.g. `images.canfar.net/skaha/astroml:24.07`. The cache
    /// keys on a sanitized form of this.
    let imageID: String

    /// Content fingerprint computed inside the container by sha256 of
    /// stable marker files (`/etc/os-release`, `/var/lib/dpkg/status`,
    /// etc.). Probe-time, NOT the Docker registry digest. Used to
    /// detect tag-content drift on rediscover. `"sha256:none"` when
    /// no marker file was readable (extremely minimal images).
    let contentHash: String

    /// When the probe ran (ISO-8601 UTC).
    let capturedAt: Date

    /// `ubuntu` / `almalinux` / `alpine` / `debian` / `unknown`.
    let osFamily: String
    /// e.g. `"22.04"` for Ubuntu, `"9"` for AlmaLinux. `"unknown"` if
    /// /etc/os-release was missing or unparseable.
    let osVersion: String
    /// `uname -srm` output, e.g. `"Linux 5.15.0-1062-aws x86_64"`.
    let kernel: String

    /// Debian/Ubuntu installed packages (via `dpkg-query`).
    let dpkgPackages: [Package]
    /// RHEL/Fedora installed packages (via `rpm -qa`).
    let rpmPackages: [Package]
    /// Alpine installed packages (via `apk info -v`).
    let apkPackages: [Package]
    /// Python packages found via `pip list --format=freeze` in the
    /// system interpreter and each conda env.
    let pythonPackages: [PythonPackage]
    /// R packages from `installed.packages()`.
    let rPackages: [Package]
    /// Conda environments — one entry per env, each with its own
    /// `pip` snapshot. Empty when `conda` isn't on PATH.
    let condaEnvs: [CondaEnv]

    /// Set when the probe completed but produced an empty / partial
    /// manifest for an explainable reason — e.g. the image lacks
    /// `dpkg`, `pip`, AND `conda` (rare). Empty manifests are still
    /// SUCCESS, not failure; this string explains the emptiness.
    let probeNotes: String?

    struct Package: Codable, Equatable, Sendable, Hashable {
        let name: String
        let version: String
    }

    struct PythonPackage: Codable, Equatable, Sendable, Hashable {
        let name: String
        let version: String
        /// `"pip"` (system), `"conda"`, or `"system"` (distro-installed
        /// python like `python3-numpy` from apt). Lets the UI
        /// distinguish `pip install astropy` from
        /// `apt-get install python3-astropy`.
        let source: String
        /// Conda env name (`""` for the system python, `"base"` for
        /// the conda root, anything else for named envs).
        let env: String
    }

    struct CondaEnv: Codable, Equatable, Sendable {
        /// `"base"` for the root, otherwise the env name.
        let name: String
        /// Path on disk inside the container (e.g. `"/opt/conda"` or
        /// `"/opt/conda/envs/astroml"`). Useful for the UI tooltip.
        let prefix: String
        let packages: [PythonPackage]
    }

    // MARK: - Codable (forward-compatible decode)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, imageID, contentHash, capturedAt
        case osFamily, osVersion, kernel
        case dpkgPackages, rpmPackages, apkPackages, pythonPackages, rPackages, condaEnvs
        case probeNotes
    }

    init(
        schemaVersion: Int,
        imageID: String,
        contentHash: String,
        capturedAt: Date,
        osFamily: String,
        osVersion: String,
        kernel: String,
        dpkgPackages: [Package] = [],
        rpmPackages: [Package] = [],
        apkPackages: [Package] = [],
        pythonPackages: [PythonPackage] = [],
        rPackages: [Package] = [],
        condaEnvs: [CondaEnv] = [],
        probeNotes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.imageID = imageID
        self.contentHash = contentHash
        self.capturedAt = capturedAt
        self.osFamily = osFamily
        self.osVersion = osVersion
        self.kernel = kernel
        self.dpkgPackages = dpkgPackages
        self.rpmPackages = rpmPackages
        self.apkPackages = apkPackages
        self.pythonPackages = pythonPackages
        self.rPackages = rPackages
        self.condaEnvs = condaEnvs
        self.probeNotes = probeNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.imageID       = try c.decode(String.self, forKey: .imageID)
        self.contentHash   = try c.decodeIfPresent(String.self, forKey: .contentHash) ?? "sha256:none"
        self.capturedAt    = try c.decode(Date.self, forKey: .capturedAt)
        self.osFamily      = try c.decodeIfPresent(String.self, forKey: .osFamily) ?? "unknown"
        self.osVersion     = try c.decodeIfPresent(String.self, forKey: .osVersion) ?? "unknown"
        self.kernel        = try c.decodeIfPresent(String.self, forKey: .kernel) ?? "unknown"
        self.dpkgPackages  = try c.decodeIfPresent([Package].self, forKey: .dpkgPackages) ?? []
        self.rpmPackages   = try c.decodeIfPresent([Package].self, forKey: .rpmPackages) ?? []
        self.apkPackages   = try c.decodeIfPresent([Package].self, forKey: .apkPackages) ?? []
        self.pythonPackages = try c.decodeIfPresent([PythonPackage].self, forKey: .pythonPackages) ?? []
        self.rPackages     = try c.decodeIfPresent([Package].self, forKey: .rPackages) ?? []
        self.condaEnvs     = try c.decodeIfPresent([CondaEnv].self, forKey: .condaEnvs) ?? []
        self.probeNotes    = try c.decodeIfPresent(String.self, forKey: .probeNotes)
    }
}

// MARK: - Sanitization helpers

extension ImageManifest {
    /// Convert an image id like `images.canfar.net/skaha/astroml:24.07`
    /// into a filesystem-safe stub:
    /// `images.canfar.net_skaha_astroml_24.07`. Used to derive both
    /// the on-disk cache filename and the in-container manifest path.
    static func sanitize(imageID: String) -> String {
        var out = ""
        out.reserveCapacity(imageID.count)
        for ch in imageID {
            switch ch {
            case "/", ":", "\\", "?", "*", "<", ">", "|", "\"":
                out.append("_")
            default:
                out.append(ch)
            }
        }
        return out
    }
}

// MARK: - Empty manifest factory (for tests / fallback UI)

extension ImageManifest {
    /// Empty manifest. Used by parser as the failure-case template
    /// when probe output is completely unparseable but we want a
    /// shape the cache can store (with `probeNotes` explaining).
    static func empty(imageID: String, notes: String) -> ImageManifest {
        ImageManifest(
            schemaVersion: 1,
            imageID: imageID,
            contentHash: "sha256:none",
            capturedAt: Date(),
            osFamily: "unknown",
            osVersion: "unknown",
            kernel: "unknown",
            probeNotes: notes
        )
    }
}
