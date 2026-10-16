// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct SessionContext: Codable {
    let cores: ResourceOptions
    let memoryGB: ResourceOptions
    let gpus: GpuOptions?

    /// What it offers in GPUs; the one rule every GPU control asks (plan 41).
    var gpuOffer: GPUOffer { GPUOffer(options: gpus?.options ?? []) }
}

extension SessionContext {
    /// Cores and memory as before; `gpus` missing, null or in a shape it
    /// does not know is no GPUs (plan 41). A strict `gpus` had failed the
    /// whole context, and the cache then kept none: the launch form lost
    /// its cores and RAM too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cores = try container.decode(ResourceOptions.self, forKey: .cores)
        memoryGB = try container.decode(ResourceOptions.self, forKey: .memoryGB)
        gpus = (try? container.decodeIfPresent(GpuOptions.self, forKey: .gpus)) ?? nil
    }
}

struct ResourceOptions: Codable {
    let `default`: Int
    let options: [Int]
}

struct GpuOptions: Codable {
    let options: [Int]
}

/// The GPUs a context offers (plan 41): the positive counts of its
/// `gpus.options`, sorted, once each. None when it has no `gpus`, no
/// options, or only 0 — the GPU controls are then disabled, and turn on by
/// themselves when a refreshed context offers some.
struct GPUOffer: Equatable, Sendable {
    let counts: [Int]

    static let none = GPUOffer(counts: [])

    init(counts: [Int]) { self.counts = counts }

    init(options: [Int]) { counts = Array(Set(options.filter { $0 > 0 })).sorted() }

    var offersAny: Bool { !counts.isEmpty }

    /// The most a batch job may ask for; 0 when none is offered.
    var largest: Int { counts.last ?? 0 }

    /// None, or one of the counts offered.
    func allows(_ gpus: Int) -> Bool { gpus == 0 || counts.contains(gpus) }

    /// A stepper's next count from `gpus`: through 0 and the counts offered,
    /// over any gap, no further than they go.
    func step(from gpus: Int, up: Bool) -> Int {
        let steps = [0] + counts
        return (up ? steps.first { $0 > gpus } : steps.last { $0 < gpus }) ?? gpus
    }

    /// "1–7", or "1, 2, 4" with a gap.
    var described: String {
        guard let first = counts.first, let last = counts.last else { return "none" }
        if counts == Array(first...last) { return first == last ? "\(first)" : "\(first)–\(last)" }
        return counts.map(String.init).joined(separator: ", ")
    }
}
