// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A VOSpace file's media type, by one rule wherever it is shown — a
/// listing (`list_vospace_path`, `get_vospace_node`) and a read
/// (`read_vospace_file`): the type its name gives — by its extension, or
/// a dotfile's — otherwise what the server stated, otherwise
/// `application/octet-stream`.
///
/// ARC states `application/octet-stream` for a file uploaded without a
/// type, so a listing that took the server's word called a `.py` binary
/// while a read called it Python.
enum VOSpaceContentType {
    static let unknown = "application/octet-stream"

    static func of(path: String, stated: String?) -> String {
        if let known = byExtension(path) ?? dotfile(path) { return known }
        if let stated, !stated.isEmpty { return stated }
        return unknown
    }

    /// The type a file's extension names, case-insensitively; nil when it names none.
    static func byExtension(_ path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "txt", "log", "ini", "conf", "toml": return "text/plain"
        case "csv": return "text/csv"
        case "tsv": return "text/tab-separated-values"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "py": return "text/x-python"
        case "sh": return "application/x-sh"
        case "md": return "text/markdown"
        case "yaml", "yml": return "application/yaml"
        case "fits", "fit", "fts": return "application/fits"
        case "gz": return "application/gzip"
        case "zip": return "application/zip"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return nil
        }
    }

    /// Binary files a platform home holds under a dotfile's name.
    private static let binaryDotfiles: Set<String> = [".ds_store", ".xauthority", ".iceauthority"]

    /// A dotfile with no extension — `.bashrc`, `.profile`, `.token` — is a
    /// settings file, text, whatever the server stated (QA L5); nil for any
    /// other name.
    static func dotfile(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.count > 1, name.hasPrefix("."), (path as NSString).pathExtension.isEmpty,
              !binaryDotfiles.contains(name.lowercased()) else { return nil }
        return "text/plain"
    }

    /// Whether a file of this type is text, to be read as UTF-8.
    static func isText(_ type: String) -> Bool {
        type.hasPrefix("text/")
            || ["application/json", "application/xml", "application/yaml", "application/x-sh"].contains(type)
    }
}
