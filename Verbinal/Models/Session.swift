// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

// Raw API response — matches Skaha JSON exactly
struct SkahaSessionResponse: Codable {
    let id: String
    let userid: String?
    let runAsUID: String?
    let runAsGID: String?
    let supplementalGroups: [Int]?
    let image: String
    let type: String
    let status: String
    let name: String
    let startTime: String
    let expiryTime: String
    let connectURL: String
    let requestedRAM: String?
    let requestedCPUCores: String?
    let requestedGPUCores: String?
    let ramInUse: String?
    let cpuCoresInUse: String?
    let isFixedResources: Bool?
}

// Normalized app-internal model
struct Session: Identifiable, Equatable {
    let id: String
    var sessionType: String
    var sessionName: String
    var status: String
    var containerImage: String
    var startedTime: String
    var expiresTime: String
    var connectUrl: String
    var memoryUsage: String
    var memoryAllocated: String
    var cpuUsage: String
    var cpuAllocated: String
    var gpuAllocated: String
    var isFixedResources: Bool

    private var statusLower: String { status.lowercased() }
    var isPending: Bool { statusLower == "pending" || statusLower == "terminating" }
    var isRunning: Bool { statusLower == "running" }
    var isFailed: Bool { statusLower == "failed" || statusLower == "error" }

    init(from raw: SkahaSessionResponse) {
        self.id = raw.id
        self.sessionType = raw.type
        self.sessionName = raw.name
        self.status = raw.status
        self.containerImage = raw.image
        self.startedTime = raw.startTime
        self.expiresTime = raw.expiryTime
        self.connectUrl = raw.connectURL
        self.memoryAllocated = raw.requestedRAM ?? ""
        self.memoryUsage = raw.ramInUse ?? ""
        self.cpuAllocated = raw.requestedCPUCores ?? ""
        self.cpuUsage = raw.cpuCoresInUse ?? ""
        self.gpuAllocated = raw.requestedGPUCores ?? ""
        self.isFixedResources = raw.isFixedResources ?? true
    }
}
