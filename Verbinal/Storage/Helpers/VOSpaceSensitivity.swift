// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Which files and folders usually hold secrets — access tokens, keys,
/// credentials, and the shell and tool configuration that exports or keeps
/// them. One rule for the Storage screen and the agent's listing.
///
/// A CANFAR home held `.token`, `.config`, `.globus-init.sh` and `.bashrc`
/// readable by anyone, and nothing said so (QA M14). A desktop session
/// leaves its VNC password in `.vnc` and its X11 cookie in `.Xauthority`.
enum VOSpaceSensitivity {
    private static let names: Set<String> = [
        ".token", ".netrc", ".pgpass", ".git-credentials", ".env", ".npmrc", ".pypirc",
        ".ssh", ".aws", ".kube", ".docker", ".gnupg", ".config", ".vnc", ".xauthority", ".iceauthority",
        ".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile",
        "id_rsa", "id_ecdsa", "id_ed25519",
    ]
    private static let prefixes = [".globus", ".cadc"]
    private static let suffixes = [".pem", ".key", ".p12", ".pfx", ".keytab"]

    /// Whether the file or folder at `path` — or a folder it is in — is one
    /// that usually holds secrets.
    static func isLikelySecret(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let name = component.lowercased()
            return names.contains(name)
                || prefixes.contains { name.hasPrefix($0) }
                || suffixes.contains { name.hasSuffix($0) }
        }
    }
}
