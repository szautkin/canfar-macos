// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A file shared as it is (plan 49): from the viewers, a file's page and On
/// This iPhone alike. Verbinal's own files go straight to the share sheet; a
/// file opened in place from the Files app is copied while Verbinal may read
/// it, so the app it goes to gets the bytes.
struct iOSFileShare: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { share in
            SentTransferredFile(try share.readable())
        }
    }

    static func preview(_ url: URL) -> SharePreview<Never, Image> {
        SharePreview(url.lastPathComponent, icon: Image(systemName: "doc"))
    }

    /// The file itself when Verbinal can read it any time; else a copy made
    /// while its access is open.
    func readable() throws -> URL {
        guard url.startAccessingSecurityScopedResource() else { return url }
        defer { url.stopAccessingSecurityScopedResource() }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shared-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}
