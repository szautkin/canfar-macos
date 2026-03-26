// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import Observation

@Observable
@MainActor
final class PlatformLoadModel {
    private let platformService: PlatformService

    var isLoading = false

    // CPU — "available" = free cores, "total" = requested + available
    var cpuAvailable: Double = 0
    var cpuTotal: Double = 0
    var cpuPercent: Double = 0

    // RAM
    var ramAvailableGB: Double = 0
    var ramTotalGB: Double = 0
    var ramPercent: Double = 0

    // Instances
    var totalInstances: Int = 0
    var sessionInstances: Int = 0
    var desktopAppInstances: Int = 0
    var headlessInstances: Int = 0
    var hasInstanceData = false

    var lastUpdate = ""
    var errorMessage = ""
    var hasError = false

    init(platformService: PlatformService) {
        self.platformService = platformService
    }

    func loadStats() async {
        isLoading = true
        hasError = false

        do {
            let stats = try await platformService.getStats()

            if let cores = stats.cores {
                cpuAvailable = cores.cpuCoresAvailable
                cpuTotal = cores.requestedCPUCores + cores.cpuCoresAvailable
                // Bar shows usage (how loaded the platform is)
                cpuPercent = cpuTotal > 0 ? (cores.requestedCPUCores / cpuTotal) * 100 : 0
            }

            if let ram = stats.ram {
                ramAvailableGB = Self.parseRamGB(ram.ramAvailable ?? "0")
                let requestedGB = Self.parseRamGB(ram.requestedRAM ?? "0")
                ramTotalGB = requestedGB + ramAvailableGB
                // Bar shows usage (how loaded the platform is)
                ramPercent = ramTotalGB > 0 ? (requestedGB / ramTotalGB) * 100 : 0
            }

            if let instances = stats.instances {
                totalInstances = instances.total ?? 0
                sessionInstances = instances.session ?? 0
                desktopAppInstances = instances.desktopApp ?? 0
                headlessInstances = instances.headless ?? 0
                hasInstanceData = true
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            lastUpdate = formatter.string(from: Date())
        } catch {
            hasError = true
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
