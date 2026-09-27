// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// A box of an image's pixels: 0-based, `x0..<x1` × `y0..<y1`, rows as
/// stored (row 0 first, FITS's y = 1).
public struct PixelBox: Equatable, Hashable, Sendable {
    public let x0: Int, y0: Int, x1: Int, y1: Int

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public var width: Int { x1 - x0 }
    public var height: Int { y1 - y0 }

    /// The pixels a sky region covers on an image, clamped to it — the
    /// pixel box around the region, as SODA returns (a circle comes back as
    /// its square). Nil when the region misses the image.
    public static func around(_ region: SkyRegion, wcs: FITSWCSTransform, width: Int, height: Int) -> PixelBox? {
        let points = (region.outline() + [region.centre]).compactMap { wcs.worldToPixel(ra: $0.ra, dec: $0.dec) }
        guard !points.isEmpty, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        // Pixel i covers i − ½ … i + ½.
        let x0 = max(0, Int((minX + 0.5).rounded(.down))), x1 = min(width, Int((maxX + 0.5).rounded(.down)) + 1)
        let y0 = max(0, Int((minY + 0.5).rounded(.down))), y1 = min(height, Int((maxY + 0.5).rounded(.down)) + 1)
        guard x0 < x1, y0 < y1 else { return nil }
        return PixelBox(x0: x0, y0: y0, x1: x1, y1: y1)
    }
}

/// Cutting a FITS file on this computer: the chosen images' pixel boxes
/// copied byte for byte — same BITPIX, BSCALE, BZERO and BLANK — under
/// their own header cards with the geometry rewritten (NAXIS, CRPIX, the
/// IRAF LTV/LTM that map back to the whole image), a HISTORY line, and new
/// CHECKSUM and DATASUM. SIP stays valid: it is relative to CRPIX. A cut
/// of a multi-extension file keeps its primary header and the cut images
/// as extensions.
public enum FITSCutter {

    /// One image of the file, and the box of it the cut keeps.
    public struct Part: Equatable, Sendable {
        public let index: Int
        public let name: String
        public let box: PixelBox
    }

    public enum Failure: Error, Equatable {
        case noImage
        case offImage
        case unknownImage(String, available: [String])
        case unreadable(String)

        /// English, for agents and logs.
        public var message: String {
            switch self {
            case .noImage: return "the file has no uncompressed 2-D image with sky coordinates to cut"
            case .offImage: return "the region falls on none of the file's images"
            case .unknownImage(let name, let available): return "the file has no image \(name); it has \(available.joined(separator: ", "))"
            case .unreadable(let why): return "the file could not be cut: \(why)"
            }
        }
    }

    /// The images a local cut can take: 2-D, uncompressed, with a WCS.
    public static func images(of file: FITSFile) -> [FITSHDUnit] {
        file.hdus.filter { $0.isImage && $0.header.naxis == 2 && !$0.header.contains("_COMPRESSED") && $0.wcs != nil }
    }

    /// How an image is named to a person or an agent: "SCI,1", "ccd07", or
    /// its index when it has no name.
    public static func name(of hdu: FITSHDUnit) -> String {
        guard let extname = hdu.header.string("EXTNAME"), !extname.isEmpty else { return "\(hdu.id)" }
        return hdu.header.contains("EXTVER") ? "\(extname),\(hdu.header.int("EXTVER"))" : extname
    }

    /// The images `region` falls on and their boxes — those named, or
    /// every image it falls on when none are.
    public static func plan(_ file: FITSFile, region: SkyRegion, images named: [String] = []) throws(Failure) -> [Part] {
        let candidates = images(of: file)
        guard !candidates.isEmpty else { throw .noImage }
        let chosen: [FITSHDUnit]
        if named.isEmpty {
            chosen = candidates
        } else {
            chosen = try named.map { wanted throws(Failure) -> FITSHDUnit in
                guard let hdu = candidates.first(where: { name(of: $0) == wanted }) else {
                    throw .unknownImage(wanted, available: candidates.map(name(of:)))
                }
                return hdu
            }
        }
        let parts = chosen.compactMap { hdu -> Part? in
            guard let wcs = hdu.wcs,
                  let box = PixelBox.around(region, wcs: wcs, width: hdu.header.naxis1, height: hdu.header.naxis2) else { return nil }
            return Part(index: hdu.id, name: name(of: hdu), box: box)
        }
        guard !parts.isEmpty else { throw .offImage }
        return parts
    }

    /// The cut file's bytes. `data` is the whole file `file` was read from.
    public static func cut(_ data: Data, file: FITSFile, parts: [Part], history: String) throws(Failure) -> Data {
        guard !parts.isEmpty else { throw .offImage }
        var out = Data()
        let primaryIsCut = parts.contains { $0.index == 0 }
        let onlyPrimary = parts.count == 1 && primaryIsCut
        if !primaryIsCut {
            guard let primary = file.hdus.first else { throw .unreadable("no primary header") }
            out += try block(cards: dataless(cards(of: primary, in: data)), data: Data())
        }
        for part in parts.sorted(by: { $0.index < $1.index }) {
            guard let hdu = file.hdus.first(where: { $0.id == part.index }) else { throw .unreadable("no HDU \(part.index)") }
            var header = rewrite(try cards(of: hdu, in: data), hdu: hdu, box: part.box, history: history)
            if hdu.id == 0 && !onlyPrimary { header = setting("EXTEND", to: "T", in: header, after: "NAXIS2") }
            out += try block(cards: header, data: pixels(of: hdu, box: part.box, in: data))
        }
        return out
    }

    // MARK: - Cards

    /// The header's own card images, END excluded.
    static func cards(of hdu: FITSHDUnit, in data: Data) throws(Failure) -> [String] {
        guard hdu.headerOffset >= 0, hdu.dataOffset <= data.count, hdu.headerOffset < hdu.dataOffset else {
            throw .unreadable("the header is outside the file")
        }
        var cards: [String] = []
        var at = hdu.headerOffset
        while at + 80 <= hdu.dataOffset {
            let card = String(decoding: data[at..<(at + 80)], as: UTF8.self)
            if card.hasPrefix("END") && card.dropFirst(3).allSatisfy({ $0 == " " }) { return cards }
            cards.append(card)
            at += 80
        }
        throw .unreadable("the header has no END")
    }

    static func keyword(of card: String) -> String {
        String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
    }

    /// A value card, fixed format: numbers right-justified to column 30.
    static func card(_ keyword: String, _ value: String, _ comment: String = "") -> String {
        let key = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
        let isString = value.hasPrefix("'")
        var text = key + "= " + (isString ? value.padding(toLength: max(20, value.count), withPad: " ", startingAt: 0)
                                          : String(repeating: " ", count: max(0, 20 - value.count)) + value)
        if !comment.isEmpty { text += " / " + comment }
        return String(text.prefix(80)).padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(format: "%.1f", value) : "\(value)".uppercased()
    }

    /// `cards` with `keyword` set to `value`: in place when present,
    /// otherwise after `after` (or before the end).
    static func setting(_ keyword: String, to value: String, in cards: [String], after: String? = nil, comment: String = "") -> [String] {
        var cards = cards
        if let i = cards.firstIndex(where: { self.keyword(of: $0) == keyword }) {
            cards[i] = card(keyword, value, comment.isEmpty ? existingComment(cards[i]) : comment)
        } else if let after, let i = cards.lastIndex(where: { self.keyword(of: $0) == after }) {
            cards.insert(card(keyword, value, comment), at: i + 1)
        } else {
            cards.append(card(keyword, value, comment))
        }
        return cards
    }

    private static func existingComment(_ card: String) -> String {
        guard let slash = card.range(of: " / ") else { return "" }
        return String(card[slash.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// The header of a cut image: its size, where its reference pixel now
    /// is, how its pixels map back to the whole image, and what was done.
    static func rewrite(_ original: [String], hdu: FITSHDUnit, box: PixelBox, history: String) -> [String] {
        let h = hdu.header
        var cards = original.filter { !["CHECKSUM", "DATASUM"].contains(keyword(of: $0)) }
        cards = setting("NAXIS1", to: "\(box.width)", in: cards)
        cards = setting("NAXIS2", to: "\(box.height)", in: cards)
        // Every WCS's reference pixel, the primary and the alternates (CRPIX1A…).
        for card in cards {
            let key = keyword(of: card)
            guard key.hasPrefix("CRPIX1") || key.hasPrefix("CRPIX2"), key.count <= 7 else { continue }
            let shift = Double(key.hasPrefix("CRPIX1") ? box.x0 : box.y0)
            cards = setting(key, to: number(h.double(key) - shift), in: cards)
        }
        let hadLTV = h.contains("LTV1") || h.contains("LTV2")
        cards = setting("LTV1", to: number(h.double("LTV1") - Double(box.x0)), in: cards, comment: hadLTV ? "" : "offset of this cutout in the image")
        cards = setting("LTV2", to: number(h.double("LTV2") - Double(box.y0)), in: cards)
        if !h.contains("LTM1_1") { cards = setting("LTM1_1", to: "1.0", in: cards) }
        if !h.contains("LTM2_2") { cards = setting("LTM2_2", to: "1.0", in: cards) }
        cards.append("HISTORY \(history) [\(box.x0 + 1):\(box.x1),\(box.y0 + 1):\(box.y1)]".prefix(80)
            .padding(toLength: 80, withPad: " ", startingAt: 0))
        return cards
    }

    /// A primary header with no data: its keywords, without the image's shape.
    static func dataless(_ original: [String]) -> [String] {
        let dropped: Set<String> = ["BSCALE", "BZERO", "BLANK", "CHECKSUM", "DATASUM"]
        var cards = original.filter { card in
            let key = keyword(of: card)
            return !dropped.contains(key) && !(key.hasPrefix("NAXIS") && key != "NAXIS")
        }
        cards = setting("NAXIS", to: "0", in: cards)
        return setting("EXTEND", to: "T", in: cards, after: "NAXIS")
    }

    // MARK: - Pixels and blocks

    static func pixels(of hdu: FITSHDUnit, box: PixelBox, in data: Data) throws(Failure) -> Data {
        let bpp = abs(hdu.header.bitpix) / 8
        let rowLength = hdu.header.naxis1 * bpp
        guard bpp > 0, hdu.dataOffset + rowLength * hdu.header.naxis2 <= data.count else {
            throw .unreadable("the image's data is shorter than its header says")
        }
        var out = Data(capacity: box.width * box.height * bpp)
        for y in box.y0..<box.y1 {
            let start = hdu.dataOffset + y * rowLength + box.x0 * bpp
            out.append(data[start..<(start + box.width * bpp)])
        }
        return out
    }

    /// One HDU: header cards with CHECKSUM and DATASUM, END, padding, data.
    static func block(cards: [String], data: Data) throws(Failure) -> Data {
        var body = data
        pad(&body, with: 0)
        let dataSum = FITSChecksum.sum(body)
        var withSums = cards + [card("CHECKSUM", "'0000000000000000'", "HDU checksum"),
                                card("DATASUM", "'\(dataSum)'", "data unit checksum")]
        let headerSum = FITSChecksum.sum(headerBytes(withSums))
        let checksum = FITSChecksum.encode(FITSChecksum.add(headerSum, dataSum))
        withSums[withSums.count - 2] = card("CHECKSUM", "'\(checksum)'", "HDU checksum")
        return headerBytes(withSums) + body
    }

    private static func headerBytes(_ cards: [String]) -> Data {
        var bytes = Data((cards + ["END".padding(toLength: 80, withPad: " ", startingAt: 0)]).joined().utf8)
        pad(&bytes, with: 0x20)
        return bytes
    }

    private static func pad(_ data: inout Data, with byte: UInt8) {
        let remainder = data.count % 2880
        if remainder != 0 { data.append(Data(repeating: byte, count: 2880 - remainder)) }
    }
}
