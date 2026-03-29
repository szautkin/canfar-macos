// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Raw API response for headless sessions — fields are optional where
/// the Skaha API omits them (e.g. startTime/expiryTime for pending jobs).
struct SkahaHeadlessResponse: Codable {
    let id: String
    let userid: String?
    let image: String
    let type: String
    let status: String
    let name: String
    let startTime: String?
    let expiryTime: String?
    let connectURL: String?
    let requestedRAM: String?
    let requestedCPUCores: String?
    let requestedGPUCores: String?
    let ramInUse: String?
    let cpuCoresInUse: String?
    let isFixedResources: Bool?
}

/// Normalized model for a headless batch job.
struct HeadlessJob: Identifiable, Equatable {
    let id: String
    var name: String
    var status: String
    var image: String
    var startedTime: String
    var expiresTime: String
    var memoryAllocated: String
    var cpuAllocated: String
    var gpuAllocated: String

    private var statusLower: String { status.lowercased() }
    var isPending: Bool { statusLower == "pending" }
    var isRunning: Bool { statusLower == "running" }
    var isFailed: Bool { statusLower == "failed" || statusLower == "error" }
    var isCompleted: Bool { statusLower == "completed" || statusLower == "succeeded" }
    var isTerminal: Bool { isCompleted || isFailed }

    /// Short image label (e.g. "terminal:1.1.2" from full registry path).
    var imageLabel: String {
        let parts = image.split(separator: "/")
        return String(parts.last ?? Substring(image))
    }

    init(from raw: SkahaHeadlessResponse) {
        self.id = raw.id
        self.name = raw.name
        self.status = raw.status
        self.image = raw.image
        self.startedTime = raw.startTime ?? ""
        self.expiresTime = raw.expiryTime ?? ""
        self.memoryAllocated = raw.requestedRAM ?? ""
        self.cpuAllocated = raw.requestedCPUCores ?? ""
        self.gpuAllocated = raw.requestedGPUCores ?? ""
    }
}
