// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

// MARK: - get_platform_load

/// Report platform-wide load on the CANFAR Science Platform: CPU cores
/// and RAM requested vs available, plus how many instances are running
/// by type. Read-only; the wiring closure fetches from Skaha.
struct GetPlatformLoadTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let instances: Instances?
        let cores: Cores?
        let ram: Ram?
        /// GPUs in use, of how many, when the platform reports them (plan 41).
        var gpu: GPU? = nil
        /// GPU fields the stats had that were not read.
        var gpuFieldsNotRead: [String] = []
        /// Says what the platform left out — it has stopped reporting
        /// instance counts (QA M20) — rather than leaving it to be guessed.
        var note: String? {
            instances == nil ? "The platform did not report how many sessions are running; list_sessions shows yours." : nil
        }

        /// Why there is no `gpu`: none reported, or fields not read yet —
        /// named, so the reader can be pinned to Skaha's.
        var gpuNote: String? {
            guard gpu == nil else { return nil }
            return gpuFieldsNotRead.isEmpty
                ? "This platform does not report GPUs."
                : "The platform's stats have GPU fields Verbinal does not read yet: \(gpuFieldsNotRead.joined(separator: ", "))."
        }

        private enum CodingKeys: String, CodingKey { case instances, cores, ram, gpu, gpuNote, note }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(instances, forKey: .instances)
            try c.encodeIfPresent(cores, forKey: .cores)
            try c.encodeIfPresent(ram, forKey: .ram)
            // Said, not left out: an assistant reads that there are none.
            try c.encode(gpu, forKey: .gpu)
            try c.encodeIfPresent(gpuNote, forKey: .gpuNote)
            try c.encodeIfPresent(note, forKey: .note)
        }

        struct GPU: Encodable, Sendable, Equatable {
            let used: Double
            let free: Double
            let total: Double
            /// The share in use, to one decimal.
            let percent: Double
        }

        struct Instances: Encodable, Sendable {
            let session: Int?
            let desktopApp: Int?
            let headless: Int?
            let total: Int?
        }

        struct Cores: Encodable, Sendable {
            let requested: Double
            let available: Double
        }

        struct Ram: Encodable, Sendable {
            let requestedGB: Double?
            let availableGB: Double?
        }
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_platform_load",
        description: "CANFAR platform load — CPU cores and RAM requested vs available; GPUs (`gpu`: used, free, total, percent) when the platform reports them, else `gpu: null` and `gpuNote` says why; and running instance counts (session / desktopApp / headless / total) when the platform reports them; it currently often does not, and `note` then says so. Use this to judge whether the platform has room before launching sessions or headless jobs.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    let fetch: @Sendable () async throws -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        try await fetch()
    }
}

extension GetPlatformLoadTool.Output {
    /// The tool's answer from Skaha's stats.
    init(stats: SkahaStatsResponse) {
        self.init(
            instances: stats.instances.map {
                .init(session: $0.session, desktopApp: $0.desktopApp, headless: $0.headless, total: $0.total)
            },
            cores: stats.cores.map { .init(requested: $0.requestedCPUCores, available: $0.cpuCoresAvailable) },
            ram: stats.ram.map {
                .init(requestedGB: $0.requestedRAM.map { PlatformLoadModel.parseRamGB($0) },
                      availableGB: $0.ramAvailable.map { PlatformLoadModel.parseRamGB($0) })
            },
            gpu: stats.gpu.flatMap { ResourceLoad(used: $0.used, total: $0.total) }.map {
                .init(used: $0.used, free: $0.free, total: $0.total, percent: ($0.percent * 10).rounded() / 10)
            },
            gpuFieldsNotRead: stats.gpuFieldsNotRead)
    }
}

// MARK: - get_storage_quota

/// Report the signed-in user's VOSpace storage usage against quota.
struct GetStorageQuotaTool: JSONReadTool {
    typealias Args = EmptyArgs

    struct Output: Encodable, Sendable {
        let usedBytes: Int64
        let quotaBytes: Int64
        let usedGB: Double
        let quotaGB: Double
        let usagePercent: Double
    }

    let definition = AIToolDefinition.withStaticSchema(
        name: "get_storage_quota",
        description: "The signed-in user's VOSpace storage usage vs quota (bytes, GB, and percent used). Requires sign-in — fails with authRequired when the user is signed out.",
        schema: #"""
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """#
    )

    /// Throws `ToolFailureReason.authRequired` when the user is signed
    /// out; the wiring closure supplies that check.
    let fetch: @Sendable () async throws -> Output

    func handle(_ args: EmptyArgs, context: AIToolContext) async throws -> Output {
        try await fetch()
    }
}
