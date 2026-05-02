// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

// MARK: - Adapt existing services to the coordinator's narrow facades

/// `HeadlessService` already has the methods we need; the conformance
/// is one-line. Kept in this module rather than mutating
/// HeadlessService.swift so the dependency arrow points the right
/// way: ImageDiscovery depends on Headless, not the reverse.
extension HeadlessService: HeadlessProbeLauncher {}

/// `VOSpaceBrowserService` likewise.
extension VOSpaceBrowserService: VOSpaceFileTransfer {}
