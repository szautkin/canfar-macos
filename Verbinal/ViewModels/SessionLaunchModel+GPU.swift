// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A session's GPUs (plans 41, 42): the Standard tab one or none, the
/// Advanced tab and a relaunch the counts the context offers; none where
/// the platform offers none.
extension SessionLaunchModel {
    /// The tab a launch is from.
    enum FormTab: Sendable {
        case standard, advanced
    }

    /// Use a GPU, the Standard tab's. Ticked, the resources become Fixed:
    /// one GPU with a fixed size is what Skaha is known to take. Unticked,
    /// Fixed stays as it is.
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

    /// What a launch from `tab` asks for: Standard one at most, Advanced
    /// the count chosen — none where it is not offered.
    func gpusToSend(from tab: FormTab) -> Int {
        guard gpuOffer.offersAny, gpus > 0 else { return 0 }
        switch tab {
        case .standard: return 1
        case .advanced: return gpuOffer.allows(gpus) ? gpus : 0
        }
    }

    /// Why `tab` cannot take `gpus`, or nil.
    func gpuRefusal(_ gpus: Int?, tab: FormTab) -> String? {
        guard let gpus, gpus > 0, knowsTheOffer else { return nil }
        guard gpuOffer.offersAny else { return "this platform offers no GPUs" }
        switch tab {
        case .standard where gpus > 1:
            return "the Standard tab takes one GPU or none (gpus 0 or 1); the Advanced tab takes 0, or one of \(gpuOffer.described)"
        case .advanced where !gpuOffer.allows(gpus):
            return "gpus \(gpus) is not offered: 0, or one of \(gpuOffer.described)"
        default:
            return nil
        }
    }

    /// A recorded launch's GPUs, relaunched (plan 42): the count recorded,
    /// while it is offered; else the largest offered below it, or none, and
    /// the status says which. Before the context is known, as recorded. One
    /// is what the Standard tab asks for, offered wherever any is.
    func relaunchGPUs(_ launch: RecentLaunch) -> (count: Int, note: String?) {
        guard launch.resourceType == "fixed", launch.gpus > 0, knowsTheOffer else {
            return (launch.resourceType == "fixed" ? launch.gpus : 0, nil)
        }
        guard gpuOffer.offersAny else {
            return (0, String(localized: "Relaunched without a GPU: this platform offers none"))
        }
        if launch.gpus == 1 || gpuOffer.allows(launch.gpus) { return (launch.gpus, nil) }
        let below = gpuOffer.counts.last { $0 < launch.gpus } ?? 1
        return (below, below == 1
            ? String(localized: "Relaunched with one GPU: this platform offers \(gpuOffer.described)")
            : String(localized: "Relaunched with \(below) GPUs: this platform offers \(gpuOffer.described)"))
    }
}
