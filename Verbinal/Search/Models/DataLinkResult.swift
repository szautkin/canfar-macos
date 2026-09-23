// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A downloadable file from DataLink (#this semantic).
struct DataLinkFile {
    let url: URL
    let contentType: String
    let filename: String

    /// True if this is an uncompressed FITS file (not .fz or .gz).
    var isUncompressedFITS: Bool {
        contentType.contains("fits") && !filename.hasSuffix(".fz") && !filename.hasSuffix(".gz")
    }

    /// JWST calibrated 2D product (`*_i2d.fits`). Preferred over
    /// association JSON and sibling catalogs when several #this rows exist.
    var isI2d: Bool {
        filename.lowercased().contains("i2d")
    }

    /// Association tables and other non-image products that DataLink
    /// sometimes lists as #this alongside the science FITS.
    var isAssociationOrAuxiliary: Bool {
        let n = filename.lowercased()
        let t = contentType.lowercased()
        return n.hasSuffix(".json") || n.hasSuffix(".xml") || n.hasSuffix(".html")
            || t.contains("json") || t.contains("xml") || t.contains("html")
    }

    /// Science-product pick: i2d FITS, then any uncompressed FITS, then
    /// any FITS, skipping association JSON when a real file exists.
    static func preferred(in files: [DataLinkFile]) -> DataLinkFile? {
        let science = files.filter { !$0.isAssociationOrAuxiliary }
        let pool = science.isEmpty ? files : science
        return pool.first(where: { $0.isUncompressedFITS && $0.isI2d })
            ?? pool.first(where: \.isUncompressedFITS)
            ?? pool.first(where: {
                $0.contentType.lowercased().contains("fits")
                    || $0.filename.lowercased().contains(".fit")
            })
            ?? pool.first
    }
}

/// Result from the CADC DataLink service — thumbnails, previews, and direct file URLs.
struct DataLinkResult {
    let thumbnails: [URL]
    let previews: [URL]
    /// Direct download URLs for science data files (#this semantic).
    let directFiles: [DataLinkFile]
    /// `error_message` / unauthorized rows that were skipped. Empty when
    /// every advertised #this row was usable.
    let faults: [String]

    init(
        thumbnails: [URL],
        previews: [URL],
        directFiles: [DataLinkFile],
        faults: [String] = []
    ) {
        self.thumbnails = thumbnails
        self.previews = previews
        self.directFiles = directFiles
        self.faults = faults
    }

    var firstThumbnail: URL? { thumbnails.first }
    var firstPreview: URL? { previews.first }
    /// Best direct file URL — prefer JWST i2d, then uncompressed FITS,
    /// then any science file. Association JSON loses to a FITS sibling.
    var bestDirectFileURL: URL? { DataLinkFile.preferred(in: directFiles)?.url }
    var isEmpty: Bool { thumbnails.isEmpty && previews.isEmpty && directFiles.isEmpty }
}

// MARK: - VOTable Parsing

extension DataLinkResult {

    /// Parse a DataLink VOTable XML response to extract thumbnail, preview, and direct file URLs.
    static func fromVOTable(_ xml: String) -> DataLinkResult {
        var thumbnails: [URL] = []
        var previews: [URL] = []
        var directFiles: [DataLinkFile] = []
        var faults: [String] = []

        // Extract FIELD names to determine column indices
        let fieldPattern = try! NSRegularExpression(pattern: #"<FIELD[^>]*name="([^"]*)"[^>]*/?>"#, options: .caseInsensitive)
        let fieldNames = fieldPattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: xml) else { return nil }
            return String(xml[range])
        }

        let accessUrlIdx = fieldNames.firstIndex(of: "access_url")
        let semanticsIdx = fieldNames.firstIndex(of: "semantics")
        let errorIdx = fieldNames.firstIndex(of: "error_message")
        let readableIdx = fieldNames.firstIndex(of: "link_authorized")
        let contentTypeIdx = fieldNames.firstIndex(of: "content_type")

        guard let accessUrlIdx, let semanticsIdx else {
            return DataLinkResult(thumbnails: [], previews: [], directFiles: [])
        }

        // Extract rows
        let trPattern = try! NSRegularExpression(pattern: #"<TR>([\s\S]*?)</TR>"#, options: .caseInsensitive)
        let tdPattern = try! NSRegularExpression(pattern: #"<TD\s*/?>([^<]*)?(?:</TD>)?"#, options: .caseInsensitive)

        for trMatch in trPattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let rowRange = Range(trMatch.range(at: 1), in: xml) else { continue }
            let rowContent = String(xml[rowRange])

            let cells = tdPattern.matches(in: rowContent, range: NSRange(rowContent.startIndex..., in: rowContent)).map { cellMatch -> String in
                guard let cellRange = Range(cellMatch.range(at: 1), in: rowContent) else { return "" }
                return String(rowContent[cellRange]).trimmingCharacters(in: .whitespaces)
            }

            let accessUrl = accessUrlIdx < cells.count ? cells[accessUrlIdx] : ""
            let semantics = semanticsIdx < cells.count ? cells[semanticsIdx] : ""

            if let errorIdx, errorIdx < cells.count, !cells[errorIdx].isEmpty {
                faults.append(cells[errorIdx])
                continue
            }
            if let readableIdx, readableIdx < cells.count, cells[readableIdx] != "true" && !cells[readableIdx].isEmpty {
                let label = accessUrl.isEmpty ? semantics : accessUrl
                faults.append("not authorized (\(label))")
                continue
            }

            guard accessUrlIdx < cells.count, semanticsIdx < cells.count else { continue }
            guard !accessUrl.isEmpty,
                  let url = URL(string: accessUrl),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" else {
                // Reject http://, file://, ftp:// — protects against SSRF /
                // plaintext downgrade if a DataLink response is malformed
                // or intercepted. The CADC services we care about are all
                // HTTPS; anything else is suspicious.
                continue
            }

            let contentType: String
            if let ctIdx = contentTypeIdx, ctIdx < cells.count {
                contentType = cells[ctIdx]
            } else {
                contentType = ""
            }

            if semantics == "#thumbnail" {
                thumbnails.append(url)
            } else if semantics == "#preview" && contentType.contains("image") {
                previews.append(url)
            } else if semantics == "#this" {
                let filename = url.lastPathComponent
                directFiles.append(DataLinkFile(url: url, contentType: contentType, filename: filename))
            }
        }

        return DataLinkResult(
            thumbnails: thumbnails, previews: previews,
            directFiles: directFiles, faults: faults
        )
    }
}
