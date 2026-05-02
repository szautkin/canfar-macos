// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Inspector-mode probe script. Runs inside a *known-good headless
/// image* (default: `images.canfar.net/skaha/terminal:1.1.2`) and
/// introspects a *different* target image — one whose `types` array
/// doesn't include `"headless"` and so can't host the in-target
/// probe (notebook / desktop / carta / firefly / contributed).
///
/// Approach: install `syft` at runtime via its official curl|sh
/// installer (puts a static binary in `~/.local/bin`), point it at
/// the target image, parse its JSON SBOM, transform into the same
/// `ImageManifest` schema the in-target probe writes. Output lands
/// at `$HOME/.verbinal/manifests/<sanitized-target-id>.json` —
/// identical path so the coordinator's existing recovery + cache
/// layers don't need to know which path produced it.
///
/// Schema-version pinned to `ImageManifest` via
/// `ManifestParser.maxSupportedSchemaVersion`. The in-container
/// `contentHash` is `"sha256:syft"` (stable string) rather than the
/// in-target probe's marker-file hash — distinguishes the strategy
/// for stale-detection without being meaningfully different per
/// image (syft is deterministic for a given image digest).
enum InspectorScript {

    static let schemaVersion: Int = 1

    /// 12-hex-char identity for the inspector script body. Used to
    /// derive the upload filename — bumping the body auto-busts
    /// any prior upload in VOSpace.
    static var scriptHash: String {
        sha256Hex(of: body).prefix(12).lowercased()
    }

    static var uploadFilename: String {
        "inspector-\(scriptHash).sh"
    }

    /// User-overridable default for the headless image that hosts
    /// inspections. UserDefaults key allows the user (or a future
    /// settings panel) to swap in a different known-good image
    /// without a recompile.
    static let inspectorImageDefaultsKey = "com.codebg.Verbinal.imageDiscovery.inspectorImage"

    /// Built-in default. `terminal` is the canonical small headless
    /// image from CADC's catalogue (also the example image in the
    /// Python `canfar` client).
    static let builtinInspectorImageID: String =
        "images.canfar.net/skaha/terminal:1.1.2"

    /// Resolved inspector image id: UserDefaults override falls
    /// through to the builtin.
    static func resolvedInspectorImageID() -> String {
        UserDefaults.standard.string(forKey: inspectorImageDefaultsKey)
            ?? builtinInspectorImageID
    }

    /// Inspector script body. Single bash file. Reads target image
    /// from `TARGET_IMAGE` env var. Atomic write via `.partial`
    /// rename. Embeds a Python transformer for syft → ImageManifest
    /// schema conversion (matches the in-target probe's JSON shape).
    static let body: String = #"""
    #!/usr/bin/env bash
    # verbinal-image-inspector v1
    # Runs inside a known-good headless container to inspect a
    # *different* target image whose own type doesn't allow
    # headless launch (notebook/desktop/carta/firefly/contributed).
    set -u

    USER_HOME="${HOME:-/arc/home/$(whoami)}"
    : "${TARGET_IMAGE:?TARGET_IMAGE env var must be set by the launcher}"

    OUT_DIR="$USER_HOME/.verbinal/manifests"
    mkdir -p "$OUT_DIR"

    SAFE_ID=$(printf '%s' "$TARGET_IMAGE" | tr '/:?*<>|"\\' '_')
    OUT="$OUT_DIR/$SAFE_ID.json"
    TMP="$OUT.partial"

    # ---- Install syft (binary, ~80MB) into ~/.local/bin if missing.
    SYFT="$(command -v syft || true)"
    if [ -z "$SYFT" ]; then
        mkdir -p "$USER_HOME/.local/bin"
        if command -v curl >/dev/null 2>&1; then
            curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
              | sh -s -- -b "$USER_HOME/.local/bin" >&2 2>&1 || true
        elif command -v wget >/dev/null 2>&1; then
            wget -qO- https://raw.githubusercontent.com/anchore/syft/main/install.sh \
              | sh -s -- -b "$USER_HOME/.local/bin" >&2 2>&1 || true
        fi
        SYFT="$USER_HOME/.local/bin/syft"
    fi

    # If syft still missing, write a minimal-error manifest so the
    # caller sees structured data (not a hung job) and can act.
    if [ ! -x "$SYFT" ]; then
        cat > "$TMP" <<MINIMAL
    {"schemaVersion":1,"imageID":"$TARGET_IMAGE","contentHash":"sha256:syft","capturedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","osFamily":"unknown","osVersion":"unknown","kernel":"unknown","dpkgPackages":[],"rpmPackages":[],"apkPackages":[],"pythonPackages":[],"rPackages":[],"condaEnvs":[],"probeNotes":"syft installation failed; inspector image lacks curl/wget or has no network egress"}
    MINIMAL
        mv "$TMP" "$OUT"
        echo "syft missing; minimal manifest written"
        exit 0
    fi

    # ---- Run syft against target image and transform output.
    if ! command -v python3 >/dev/null 2>&1; then
        cat > "$TMP" <<MINIMAL
    {"schemaVersion":1,"imageID":"$TARGET_IMAGE","contentHash":"sha256:syft","capturedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","osFamily":"unknown","osVersion":"unknown","kernel":"unknown","dpkgPackages":[],"rpmPackages":[],"apkPackages":[],"pythonPackages":[],"rPackages":[],"condaEnvs":[],"probeNotes":"python3 not found in inspector image; cannot transform syft output"}
    MINIMAL
        mv "$TMP" "$OUT"
        exit 0
    fi

    # Use OCI registry directly — syft handles image pulls itself.
    "$SYFT" "registry:$TARGET_IMAGE" -o syft-json 2>/dev/null \
      | python3 - <<'PYEOF' > "$TMP"
    import json, sys, os, time

    target = os.environ["TARGET_IMAGE"]

    try:
        sbom = json.load(sys.stdin)
    except Exception as e:
        print(json.dumps({
            "schemaVersion": 1,
            "imageID": target,
            "contentHash": "sha256:syft",
            "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "osFamily": "unknown", "osVersion": "unknown", "kernel": "unknown",
            "dpkgPackages": [], "rpmPackages": [], "apkPackages": [],
            "pythonPackages": [], "rPackages": [], "condaEnvs": [],
            "probeNotes": f"syft output unreadable: {e}"
        }, separators=(",", ":")))
        sys.exit(0)

    artifacts = sbom.get("artifacts", [])
    distro = sbom.get("distro", {}) or {}

    dpkg, rpm_pkgs, apk_pkgs, py_pkgs, r_pkgs = [], [], [], [], []
    conda_env_packages = {}

    def env_for(locations):
        for loc in locations:
            path = loc.get("path", "") or ""
            if "/conda/envs/" in path:
                return path.split("/conda/envs/")[1].split("/")[0]
            if path.startswith("/opt/conda/") or "/conda-meta/" in path:
                return "base"
        return ""

    for a in artifacts:
        name = a.get("name") or ""
        version = a.get("version") or ""
        if not name:
            continue
        typ = (a.get("type") or "").lower()
        if typ in ("deb", "dpkg"):
            dpkg.append({"name": name, "version": version})
        elif typ == "rpm":
            rpm_pkgs.append({"name": name, "version": version})
        elif typ in ("apk", "alpine-apk"):
            apk_pkgs.append({"name": name, "version": version})
        elif typ in ("python", "wheel", "egg-info", "python-package"):
            env = env_for(a.get("locations", []) or [])
            py_pkgs.append({
                "name": name, "version": version,
                "source": "conda" if env else "pip",
                "env": env or "system"
            })
            if env:
                conda_env_packages.setdefault(env, []).append({
                    "name": name, "version": version,
                    "source": "conda", "env": env
                })
        elif typ in ("r-package", "r"):
            r_pkgs.append({"name": name, "version": version})

    conda_envs = [
        {"name": env, "prefix": "/opt/conda" if env == "base" else f"/opt/conda/envs/{env}",
         "packages": pkgs}
        for env, pkgs in sorted(conda_env_packages.items())
    ]

    notes = None
    if not (dpkg or rpm_pkgs or apk_pkgs or py_pkgs or r_pkgs):
        notes = "syft scan returned no recognisable packages"

    manifest = {
        "schemaVersion": 1,
        "imageID": target,
        "contentHash": "sha256:syft",
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "osFamily": (distro.get("name") or "unknown").lower(),
        "osVersion": distro.get("version") or "unknown",
        "kernel": "unknown (static layer scan)",
        "dpkgPackages": dpkg,
        "rpmPackages": rpm_pkgs,
        "apkPackages": apk_pkgs,
        "pythonPackages": py_pkgs,
        "rPackages": r_pkgs,
        "condaEnvs": conda_envs,
    }
    if notes:
        manifest["probeNotes"] = notes

    print(json.dumps(manifest, separators=(",", ":")))
    PYEOF

    mv "$TMP" "$OUT"
    echo "ok: $OUT"
    """#

    private static func sha256Hex(of string: String) -> String {
        let data = Data(string.utf8)
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return String(string.hashValue)
        #endif
    }
}
