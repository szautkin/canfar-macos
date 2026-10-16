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
    /// get_platform_load to name: Skaha publishes its GPUs after this was
    /// written, and the reader is pinned to them once they are seen.
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

/// How many GPUs are in use, of how many (plan 41). Read from the stats in
/// one of two shapes, under `gpus` or `gpu`:
/// - Skaha's own, as for CPU and RAM: a count named `requested…` in use,
///   and a total named `…Available`;
/// - the Science Portal's: `used` and `free`, with `maxValues.gpu`.
/// Numbers or numeric strings. Anything else, or numbers that make no
/// sense, is no GPU data.
struct GPUStats: Equatable, Sendable {
    let used: Double
    let total: Double

    /// The GPUs read, or the GPU fields that were there but not read.
    static func read(_ top: KeyedDecodingContainer<StatsKey>) -> (GPUStats?, [String]) {
        let maxGPU = (try? top.nestedContainer(keyedBy: StatsKey.self, forKey: StatsKey("maxValues")))
            .flatMap { number($0, StatsKey("gpu")) }
        for name in ["gpus", "gpu"] {
            guard let inner = try? top.nestedContainer(keyedBy: StatsKey.self, forKey: StatsKey(name)) else { continue }
            if let read = skahas(inner) ?? portals(inner, total: maxGPU) { return (read, []) }
        }
        return (nil, fieldsNamed(top, hasNumbers: maxGPU != nil))
    }

    private static func skahas(_ inner: KeyedDecodingContainer<StatsKey>) -> GPUStats? {
        let requested = inner.allKeys.first { $0.stringValue.lowercased().hasPrefix("requested") }
        let available = inner.allKeys.first { $0.stringValue.lowercased().hasSuffix("available") }
        guard let requested, let available,
              let used = number(inner, requested), let total = number(inner, available) else { return nil }
        return sensible(used: used, total: total)
    }

    private static func portals(_ inner: KeyedDecodingContainer<StatsKey>, total: Double?) -> GPUStats? {
        guard let used = number(inner, StatsKey("used")) else { return nil }
        guard let total = total ?? number(inner, StatsKey("free")).map({ used + $0 }) else { return nil }
        return sensible(used: used, total: total)
    }

    private static func sensible(used: Double, total: Double) -> GPUStats? {
        guard total > 0, used >= 0, used <= total else { return nil }
        return GPUStats(used: used, total: total)
    }

    /// Every field whose name says GPU, with what is inside it.
    private static func fieldsNamed(_ top: KeyedDecodingContainer<StatsKey>, hasNumbers maxGPU: Bool) -> [String] {
        var names: [String] = []
        for key in top.allKeys where key.stringValue.lowercased().contains("gpu") {
            if let inner = try? top.nestedContainer(keyedBy: StatsKey.self, forKey: key), !inner.allKeys.isEmpty {
                names += inner.allKeys.map { "\(key.stringValue).\($0.stringValue)" }
            } else {
                names.append(key.stringValue)
            }
        }
        if maxGPU { names.append("maxValues.gpu") }
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
