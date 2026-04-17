// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

/// VerbinalKit — shared core for the Verbinal host app and every Verbinal addon.
///
/// The package ships a single library target right now. Subsystems are organized
/// into source subdirectories (`Network/`, `Auth/`, `Keychain/`, `Storage/`,
/// `Addons/`, `Models/`). Any subsystem can be extracted into its own product
/// later — the `Package.swift` is the gate; source files are structured to make
/// that future split cheap.
public enum VerbinalKit {
    /// Version of the VerbinalKit source tree. Bumped whenever the public API
    /// surface changes in a way addons need to know about.
    public static let version = "0.1.0"
}
