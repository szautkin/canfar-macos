// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// An interactive session's GPU (plan 41): one or none, and none where the
/// platform offers none.
extension SessionLaunchModel {
    /// Use a GPU. Ticked, the resources become Fixed: one GPU with a fixed
    /// size is what Skaha is known to take. Unticked, Fixed stays as it is.
    var usesAGPU: Bool {
        get { gpus > 0 }
        set {
            guard newValue, gpuOffer.offersAny else {
                gpus = 0
                return
            }
            if resourceType != "fixed" { resourceType = "fixed" }
            gpus = 1
        }
    }

    /// The context as the cache has it now: a refresh — Settings' Refresh
    /// Now, the day-old one — brings the offer to an open form, without
    /// resetting the person's choices.
    func followOffer() {
        if let context = cacheService?.cache?.context { gpuOffer = context.gpuOffer }
    }

    /// The context has loaded: before then, nothing is judged against it.
    var knowsTheOffer: Bool { !coreOptions.isEmpty }

    /// Why the form cannot take `gpus` for an interactive session, or nil.
    func gpuRefusal(_ gpus: Int?) -> String? {
        guard let gpus else { return nil }
        if gpus > 1 { return "an interactive session takes at most one GPU (gpus 0 or 1); batch jobs take more" }
        if gpus == 1, knowsTheOffer, !gpuOffer.offersAny { return "this platform offers no GPUs" }
        return nil
    }

    /// A recorded launch's GPUs, relaunched: one at most; none where the
    /// platform offers none, once its context is known — and then said.
    func relaunchGPUs(_ launch: RecentLaunch) -> (count: Int, dropped: Bool) {
        guard launch.resourceType == "fixed", launch.gpus > 0 else { return (0, false) }
        if knowsTheOffer, !gpuOffer.offersAny { return (0, true) }
        return (1, false)
    }
}
