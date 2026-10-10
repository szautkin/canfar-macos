// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A result the app wrote, put in the person's storage (plan 36 2.11): a
/// search export, a Research bundle. The one way a result goes there; plan
/// 36 item 4.1 grows it into where every result is kept.
struct ResultUpload {
    /// Where results go when no folder is named.
    static let defaultFolder = "Verbinal-Exports"

    let vospace: VOSpaceBrowserService
    let username: String

    /// Where `file` goes for `path`, from the person's home: a path ending
    /// in the file's extension names the file; any other is a folder it goes
    /// into, keeping its name; none is the default folder.
    static func remotePath(for file: URL, in path: String?, username: String) throws -> String {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(defaultFolder)/\(file.lastPathComponent)"
        }
        let relative: String
        do {
            relative = try VOSpaceRelativePath.normalize(path, username: username)
        } catch {
            throw VOSpaceError.invalidPath
        }
        guard !relative.isEmpty else { return file.lastPathComponent }  // the home folder itself
        let ext = file.pathExtension.lowercased()
        if !ext.isEmpty, relative.lowercased().hasSuffix(".\(ext)") { return relative }
        return "\(relative)/\(file.lastPathComponent)"
    }

    /// `file` renamed `<stem>-<time>.<ext>` beside it, as results are named.
    static func stamped(_ file: URL, stem: String, at date: Date = Date()) throws -> URL {
        let named = file.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-\(SharedFormatters.fileNameStamp.string(from: date)).\(file.pathExtension)")
        try FileHelper.moveReplacing(from: file, to: named)
        return named
    }

    /// Uploads `file`, making the folders it needs first; returns where it went.
    @discardableResult
    func upload(_ file: URL, to path: String? = nil) async throws -> String {
        let remote = try Self.remotePath(for: file, in: path, username: username)
        try await vospace.ensureFolder(username: username, path: remote.split(separator: "/").dropLast().joined(separator: "/"))
        try await vospace.uploadFile(username: username, remotePath: remote, fileURL: file)
        return remote
    }
}
