// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation

/// One resource's load: how much is in use, of how much (plan 41). There is
/// none unless the platform reported a total.
struct ResourceLoad: Equatable, Sendable {
    let used: Double
    let total: Double

    init?(used: Double, total: Double) {
        guard total > 0, used >= 0 else { return nil }
        self.used = min(used, total)
        self.total = total
    }

    var free: Double { total - used }

    /// The share in use, 0 to 100.
    var percent: Double { used / total * 100 }
}

@Observable
@MainActor
final class PlatformLoadModel: PhaseOwner {
    private let platformService: PlatformService

    /// Loading, loaded (when), or why not (plan 38); what loaded last stays.
    private(set) var load: Phase<Date> = .idle

    /// Each refresh decides them again: a resource the stats leave out has
    /// none, and GPUs light up at the first refresh that has them (plan 41).
    private(set) var cpu: ResourceLoad?
    private(set) var ram: ResourceLoad?
    private(set) var gpu: ResourceLoad?
    /// GPU fields the stats carried that were not read; for the tool.
    private(set) var gpuFieldsNotRead: [String] = []

    // Instances
    var totalInstances: Int = 0
    var sessionInstances: Int = 0
    var desktopAppInstances: Int = 0
    var headlessInstances: Int = 0
    var hasInstanceData = false

    init(platformService: PlatformService) {
        self.platformService = platformService
    }

    func loadStats() async {
        await run(\.load) {
            let stats = try await platformService.getStats()
            // cpuCoresAvailable and ramAvailable are the cluster's capacity;
            // requested… is what is in use.
            cpu = stats.cores.flatMap { ResourceLoad(used: $0.requestedCPUCores, total: $0.cpuCoresAvailable) }
            ram = stats.ram.flatMap { ram in
                ram.ramAvailable.flatMap {
                    ResourceLoad(used: Self.parseRamGB(ram.requestedRAM ?? "0"), total: Self.parseRamGB($0))
                }
            }
            gpu = stats.gpu.flatMap { ResourceLoad(used: $0.used, total: $0.total) }
            gpuFieldsNotRead = stats.gpuFieldsNotRead

            if let instances = stats.instances {
                totalInstances = instances.total ?? 0
                sessionInstances = instances.session ?? 0
                desktopAppInstances = instances.desktopApp ?? 0
                headlessInstances = instances.headless ?? 0
                hasInstanceData = true
            }

            return Date()
        }
    }

    /// Parses RAM strings like "16G", "512Mi", "2T" to a Double in GB.
    nonisolated static func parseRamGB(_ ramString: String) -> Double {
        let s = ramString.trimmingCharacters(in: .whitespaces)

        if let v = stripSuffix(s, suffixes: ["GB", "Gi", "G"]) { return v }
        if let v = stripSuffix(s, suffixes: ["MB", "Mi", "M"]) { return v / 1024.0 }
        if let v = stripSuffix(s, suffixes: ["TB", "Ti", "T"]) { return v * 1024.0 }

        return Double(s) ?? 0
    }

    nonisolated private static func stripSuffix(_ s: String, suffixes: [String]) -> Double? {
        for suffix in suffixes {
            if s.hasSuffix(suffix) {
                return Double(String(s.dropLast(suffix.count)))
            }
        }
        return nil
    }
}
