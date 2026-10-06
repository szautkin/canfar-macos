// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
@testable import Verbinal

/// The platform's sessions, in memory: launches add one, deletes remove it.
final class FakeComputeSessions: ComputeSessions, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Session]
    private(set) var launched: [SessionLaunchParams] = []
    private(set) var deleted: [String] = []

    init(_ sessions: [Session] = []) { list = sessions }

    func getSessions() async throws -> [Session] { lock.withLock { list } }

    /// The platform's events, by session id.
    var events: [String: String] = [:]
    func getSessionEvents(id: String) async throws -> String { lock.withLock { events[id] ?? "" } }

    func launchSession(_ params: SessionLaunchParams) async throws -> String? {
        lock.withLock {
            launched.append(params)
            list.append(.compute(id: "launched-\(launched.count)", status: "Pending"))
        }
        return "launched-\(launched.count)"
    }

    func deleteSession(id: String) async throws {
        lock.withLock {
            deleted.append(id)
            list.removeAll { $0.id == id }
        }
    }
}

/// The person's home on /arc, in memory: uploads and folders are recorded,
/// and `files` answers reads.
final class FakeComputeFiles: ComputeFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private(set) var uploads: [String: Data] = [:]
    private(set) var folders: [String] = []
    var failUploads = false

    func put(_ path: String, _ text: String) { lock.withLock { stored[path] = Data(text.utf8) } }

    func uploadFile(username: String, remotePath: String, fileURL: URL) async throws {
        if failUploads { throw URLError(.notConnectedToInternet) }
        let data = try Data(contentsOf: fileURL)
        lock.withLock { uploads[remotePath] = data }
    }

    func createFolder(username: String, parentPath: String, folderName: String) async throws {
        lock.withLock { folders.append(parentPath.isEmpty ? folderName : "\(parentPath)/\(folderName)") }
    }

    func readFile(username: String, path: String, maxBytes: Int) async throws -> Data? {
        lock.withLock { stored[path] }
    }
}

extension Session {
    /// A session as the platform lists the compute one (or another, by name and type).
    static func compute(id: String, status: String, name: String = RunCodeContract.sessionName,
                        type: String = RunCodeContract.sessionType, startedTime: String = "",
                        image: String = "images.canfar.net/p/compute:1", ram: String = "8G", cores: String = "2") -> Session {
        Session(from: SkahaSessionResponse(
            id: id, userid: nil, runAsUID: nil, runAsGID: nil, supplementalGroups: nil,
            image: image, type: type, status: status, name: name,
            startTime: startedTime, expiryTime: "", connectURL: "", requestedRAM: ram, requestedCPUCores: cores,
            requestedGPUCores: nil, ramInUse: nil, cpuCoresInUse: nil, isFixedResources: true))
    }
}
