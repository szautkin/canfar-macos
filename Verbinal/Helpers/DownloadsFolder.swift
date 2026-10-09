// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os

/// The person's download folder — where files land that nobody chose a
/// place for (an observation's files, an assistant's downloads, a cutout's
/// companions, an export) — the one place that says where it is. It is
/// `~/Downloads` until the person chooses another (plan 34 F,
/// `DownloadFolderSetting`).
///
/// In the sandbox, FileManager names the container's Downloads, a link to
/// `~/Downloads` (the `files.downloads.read-write` entitlement): the same
/// folder by another path, so figure exports read as landing somewhere
/// else than downloads (plan 19 F2, QA L9). Every path here is resolved.
enum DownloadsFolder {

    /// The download folder: the one the person chose, while it is there,
    /// else `~/Downloads`.
    static var url: URL { chosen.withLock { $0 } ?? system }

    /// `~/Downloads`, as the person knows it.
    static var system: URL {
        ((try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true))
            .resolvingSymlinksInPath()
    }

    /// The folder the person chose, opened for the app's run; nil for
    /// `~/Downloads`. Set by `DownloadFolderSetting` alone.
    static let chosen = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// `<folder>/<stem>-<yyyyMMdd-HHmmss>.<ext>`, for an export.
    static func timestampedURL(stem: String, ext: String, at date: Date = Date()) -> URL {
        url.appendingPathComponent("\(stem)-\(SharedFormatters.fileNameStamp.string(from: date)).\(ext)")
    }

    /// A path kept before, as the person knows it: through the container's
    /// link, `~/Downloads/…`; any other path as it is.
    static func displayPath(_ path: String) -> String {
        path.isEmpty ? path : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Moves `file` into `folder` (default the download folder) as `name`;
    /// a file of that name already there is kept, and this one gets a
    /// timestamp.
    static func move(_ file: URL, named name: String, into folder: URL? = nil) throws -> URL {
        let dir = folder ?? url
        var target = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            target = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(stamp)" : "\(base)-\(stamp).\(ext)")
        }
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}
