// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

struct SkahaStatsResponse: Decodable {
    let instances: InstanceStats?
    let cores: CoreStats?
    let ram: RamStats?
    /// GPUs, when the stats carry them in a shape it reads (plan 41).
    let gpu: GPUStats?
    /// GPU fields the stats carry that it could not read, for
    /// get_platform_load to name: a shape Skaha may change to.
    let gpuFieldsNotRead: [String]

    private enum CodingKeys: String, CodingKey { case instances, cores, ram }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instances = try container.decodeIfPresent(InstanceStats.self, forKey: .instances)
        cores = try container.decodeIfPresent(CoreStats.self, forKey: .cores)
        ram = try container.decodeIfPresent(RamStats.self, forKey: .ram)
        (gpu, gpuFieldsNotRead) = GPUStats.read(try decoder.container(keyedBy: StatsKey.self))
    }
}

struct InstanceStats: Codable {
    let session: Int?
    let desktopApp: Int?
    let headless: Int?
    let total: Int?
}

// CPU core values may arrive as a number or a string from the API.
struct CoreStats: Codable {
    let requestedCPUCores: Double
    let cpuCoresAvailable: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestedCPUCores = Self.flexibleDouble(from: container, forKey: .requestedCPUCores)
        cpuCoresAvailable = Self.flexibleDouble(from: container, forKey: .cpuCoresAvailable)
    }

    private static func flexibleDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double {
        if let v = try? container.decode(Double.self, forKey: key) { return v }
        if let s = try? container.decode(String.self, forKey: key),
           let v = Double(s) { return v }
        return 0
    }

    enum CodingKeys: String, CodingKey {
        case requestedCPUCores, cpuCoresAvailable
    }
}

struct RamStats: Codable {
    let requestedRAM: String?
    let ramAvailable: String?
}

/// How many GPUs are in use, of how many, and the most for one session —
/// Skaha's `gpu` block on `view=stats` (plan 42): `requestedGPU` in use,
/// `gpuAvailable` the cluster's total (as `cpuCoresAvailable` is for CPU),
/// `maxGPU` the most one session may ask for. Numbers or numeric strings.
/// Absent or null when the cluster does not report GPUs; numbers that make
/// no sense are no GPU data.
struct GPUStats: Equatable, Sendable {
    let used: Double
    let total: Double
    var perSession: Double? = nil

    private static let block = StatsKey("gpu")
    private static let requested = StatsKey("requestedGPU")
    private static let available = StatsKey("gpuAvailable")
    private static let most = StatsKey("maxGPU")

    /// The GPUs read, or the GPU fields that were there but not read.
    static func read(_ top: KeyedDecodingContainer<StatsKey>) -> (GPUStats?, [String]) {
        if let inner = try? top.nestedContainer(keyedBy: StatsKey.self, forKey: block),
           let used = number(inner, requested), let total = number(inner, available),
           total > 0, used >= 0, used <= total {
            return (GPUStats(used: used, total: total, perSession: number(inner, most)), [])
        }
        return (nil, fieldsNamed(top))
    }

    /// Every field whose name says GPU, with what is inside it; a null
    /// block is the cluster saying it has none, and names nothing.
    private static func fieldsNamed(_ top: KeyedDecodingContainer<StatsKey>) -> [String] {
        var names: [String] = []
        for key in top.allKeys where key.stringValue.lowercased().contains("gpu") {
            if (try? top.decodeNil(forKey: key)) == true { continue }
            if let inner = try? top.nestedContainer(keyedBy: StatsKey.self, forKey: key), !inner.allKeys.isEmpty {
                names += inner.allKeys.map { "\(key.stringValue).\($0.stringValue)" }
            } else {
                names.append(key.stringValue)
            }
        }
        return names.sorted()
    }

    private static func number(_ container: KeyedDecodingContainer<StatsKey>, _ key: StatsKey) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let text = try? container.decode(String.self, forKey: key) { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

/// Any key of the stats, by its name.
struct StatsKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
