// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import Observation
import VerbinalKit

/// One opened file, header first (plan 47 3.2): its HDUs and headers are read
/// where the file is — in storage, by ranges — before any pixels move. Then,
/// when the person asks, the file itself comes down into the cache.
@Observable
@MainActor
final class FileInspection: PhaseOwner, Identifiable {
    let file: FileRef
    nonisolated var id: String { file.id }

    /// The HDUs, read from the headers alone.
    private(set) var structure: Phase<[FITSHDUnit]> = .idle
    /// The file on this device: kept, in the cache, or where the person has it.
    private(set) var local: Phase<URL> = .idle
    /// How much of a download has arrived, 0 to 1.
    private(set) var progress: Double = 0

    private let storage: VOSpaceBrowserService
    private let username: String
    private let files: DeviceFiles
    private var downloadTask: Task<Void, Never>?

    init(file: FileRef, storage: VOSpaceBrowserService, username: String, files: DeviceFiles = DeviceFiles()) {
        self.file = file
        self.storage = storage
        self.username = username
        self.files = files
        if let device = file.deviceURL() {
            files.noteOpened(device)
            local = .ready(device)
        } else if let copy = files.localCopy(of: file) {
            local = .ready(copy)
        }
    }

    /// A spectral cube (NAXIS ≥ 3): it opens in Cube.
    var isCube: Bool { !FITSCube.findCubeHDUs(structure.value ?? []).isEmpty }

    /// Reads the headers: from the file on this device when it is here, else
    /// from storage by ranges.
    func inspect() async {
        let file = file, storage = storage, user = username
        let localURL = local.value
        await run(\.structure) {
            if let localURL {
                let scoped = localURL.startAccessingSecurityScopedResource()
                defer { if scoped { localURL.stopAccessingSecurityScopedResource() } }
                return try await FITSCube.parseStructure(source: try LocalFileCubeSource(url: localURL))
            }
            guard case .storage(let path) = file.place else { return [] }
            let size = try await Self.size(of: file, path: path, storage: storage, user: user)
            let source = RemoteCubeDataSource(name: file.name, size: size) { offset, length in
                let read = try await storage.readRange(username: user, path: path, offset: offset, length: length)
                guard read.honoredRange || offset == 0 else { throw RangeNotSupported() }
                return read.data
            }
            return try await FITSCube.parseStructure(source: source)
        }
    }

    /// The file's size: from the listing, else from storage's answer to a first range.
    private nonisolated static func size(of file: FileRef, path: String, storage: VOSpaceBrowserService,
                                         user: String) async throws -> Int {
        if let size = file.size, size > 0 { return Int(size) }
        let first = try await storage.readRange(username: user, path: path, offset: 0, length: 2880)
        guard let total = first.totalBytes else { throw RangeNotSupported() }
        return total
    }

    /// Downloads the file from storage into the cache, with progress; Cancel stops it.
    func download() {
        guard file.isRemote, !local.isWorking else { return }
        progress = 0
        let file = file, storage = storage, user = username, files = files
        downloadTask = Task {
            await run(\.local) {
                try await StorageActions.download(file, storage: storage, username: user, into: files) { fraction in
                    Task { @MainActor in self.progress = fraction }
                }
            }
        }
    }

    /// This device's copy was deleted (plan 48): the file is still in storage.
    func forgetLocal() {
        guard file.isRemote else { return }
        cancelDownload()
        local = .idle
        progress = 0
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }
}
