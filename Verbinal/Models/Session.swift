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
