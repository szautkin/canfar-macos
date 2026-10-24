// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Darwin
import Foundation

/// A file's origin, kept on the file as an extended attribute: it moves with
/// the file, leaves no extra file in the Files app, and goes when it goes.
/// Only Verbinal's own files carry one.
extension FileOrigin {
    static let attribute = "com.codebg.verbinal.origin"

    /// The origin noted on the file at `url`, if any.
    static func read(from url: URL) -> FileOrigin? {
        url.withUnsafeFileSystemRepresentation { path -> FileOrigin? in
            guard let path else { return nil }
            let length = getxattr(path, attribute, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, length, 0, 0) }
            guard read == length else { return nil }
            return try? JSONDecoder().decode(FileOrigin.self, from: data)
        }
    }

    /// Notes this origin on the file at `url`.
    func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return data.withUnsafeBytes { setxattr(path, Self.attribute, $0.baseAddress, data.count, 0, 0) }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
    }

    /// Notes that the file at `url` was opened now.
    static func markOpened(_ url: URL, at date: Date = Date()) {
        var origin = read(from: url) ?? FileOrigin()
        origin.opened = date
        try? origin.write(to: url)
    }
}
