// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log

/// A session log kept on this Mac, as the list shows it.
struct StoredSessionLog: Sendable, Equatable, Identifiable {
    let url: URL
    let header: SessionLogHeader
    let bytes: Int
    /// When its last entry happened.
    let lastAt: Date
    let entries: Int
    let actions: Int
    let failures: Int
    /// How it ended; nil while open.
    let ending: String?

    var id: UUID { header.session }
}

/// The session logs' files: one JSON Lines file per session, its header
/// first, each entry appended as it happens, in
/// `Application Support/Verbinal/AgentSessions` (plan 23 L2). Reading,
/// listing and deleting are here and nowhere else — the journal, the
/// person's view and the assistant's tools all come through it.
final class SessionLogStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "SessionLog")

    let directory: URL
    /// One writer at a time.
    private let lock = NSLock()

    static var productionDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Verbinal/AgentSessions", isDirectory: true)
    }

    init(directory: URL = SessionLogStore.productionDirectory) {
        self.directory = directory
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// One line of JSON.
    static func line(_ record: SessionLogRecord) -> Data {
        ((try? encoder.encode(record)) ?? Data()) + Data("\n".utf8)
    }

    // MARK: - Writing

    /// Starts a session's file with its header; returns where it is.
    @discardableResult
    func create(_ header: SessionLogHeader) throws -> URL {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(Self.stamp.string(from: header.opened))-\(header.session.uuidString.prefix(8)).jsonl"
            let url = directory.appendingPathComponent(name)
            try Self.line(SessionLogRecord(header: header)).write(to: url, options: .atomic)
            return url
        }
    }

    /// Appends `entry`; returns the file's size.
    @discardableResult
    func append(_ entry: SessionLogEntry, to url: URL) throws -> Int {
        try lock.withLock {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Self.line(SessionLogRecord(entry: entry)))
            return Int(try handle.offset())
        }
    }

    /// Writes the file anew: `header`, then `entries`.
    @discardableResult
    func rewrite(_ url: URL, header: SessionLogHeader, entries: [SessionLogEntry]) throws -> Int {
        try lock.withLock {
            var data = Self.line(SessionLogRecord(header: header))
            for entry in entries { data.append(Self.line(SessionLogRecord(entry: entry))) }
            try data.write(to: url, options: .atomic)
            return data.count
        }
    }

    // MARK: - Reading

    /// A session's header and entries; nil when the file is not a log. A
    /// line it cannot read is skipped (ETC: a newer entry's shape).
    func read(_ url: URL) -> (header: SessionLogHeader, entries: [SessionLogEntry])? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var header: SessionLogHeader?
        var entries: [SessionLogEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let record = try? Self.decoder.decode(SessionLogRecord.self, from: Data(line)) else { continue }
            if let first = record.header, header == nil { header = first }
            if let entry = record.entry { entries.append(entry) }
        }
        return header.map { ($0, entries) }
    }

    /// Every session kept, newest first.
    func list() -> [StoredSessionLog] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension == "jsonl" } ?? []
        return files.compactMap { url -> StoredSessionLog? in
            guard let (header, entries) = read(url) else { return nil }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let ending = entries.last(where: { $0.kind == .closed })?.outcome
            return StoredSessionLog(url: url, header: header, bytes: bytes, lastAt: entries.last?.at ?? header.opened,
                                    entries: entries.count, actions: entries.filter { $0.kind == .action }.count,
                                    failures: entries.filter(\.isFailure).count, ending: ending)
        }
        .sorted { $0.header.opened > $1.header.opened }
    }

    func url(of session: UUID) -> URL? {
        list().first { $0.header.session == session }?.url
    }

    // MARK: - Removing

    /// Deletes these sessions' files; returns the ones deleted.
    @discardableResult
    func delete(_ sessions: Set<UUID>) -> [UUID] {
        list().filter { sessions.contains($0.header.session) }.compactMap { log in
            do {
                try lock.withLock { try FileManager.default.removeItem(at: log.url) }
                return log.header.session
            } catch {
                Self.logger.error("delete \(log.url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// Holds `url` for an open session: an exclusive advisory lock, so no
    /// other Verbinal — a test host sharing the container — takes it for
    /// abandoned. Nil when another holds it. The lock goes with the handle.
    static func hold(_ url: URL) -> FileHandle? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            return nil
        }
        return handle
    }

    /// A session left open by a quit or a crash is closed as "Verbinal quit",
    /// at its last entry's time — one no open journal holds, here or in
    /// another process.
    func closeAbandoned(open: Set<UUID>) {
        for log in list() where log.ending == nil && !open.contains(log.header.session) {
            guard let held = Self.hold(log.url) else { continue }
            defer { try? held.close() }
            guard let (_, entries) = read(log.url) else { continue }
            var closing = SessionLogLine.closed(.verbinalQuit, at: log.lastAt)
            closing.token = (entries.last?.token ?? 0) + 1
            _ = try? append(closing, to: log.url)
        }
    }

    /// Applies the retention rule; returns the sessions it removed.
    @discardableResult
    func applyRetention(open: Set<UUID>, now: Date = Date()) -> [UUID] {
        delete(Set(SessionLogRetention.toRemove(list(), open: open, now: now).map(\.header.session)))
    }
}
