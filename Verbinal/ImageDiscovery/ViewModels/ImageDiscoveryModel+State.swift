// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// What the discovery sheet's footer says (plan 38): why the catalogue or
/// the person's last action did not go, else what a recovery found.
extension ImageDiscoveryModel {
    /// While a `discoverAll` stream is in flight.
    var isDiscoveryRunning: Bool { discovery.isWorking }

    /// The problem to show: the last action's, else the catalogue's.
    var problem: Problem? { actions.problem ?? catalogue.problem }

    /// The person put the banner away.
    func dismissBanner() {
        actions.dismiss()
        catalogue.dismiss()
        recoveryNote = nil
    }

    /// Number of rows currently in the failed state. Drives the
    /// "Clear all errors (N)" button visibility / label in the
    /// sheet header.
    var failedCount: Int {
        rowStates.values.reduce(into: 0) { acc, state in
            if case .failed = state { acc += 1 }
        }
    }
}
