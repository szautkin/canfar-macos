// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation
import VerbinalKit

/// Which part of a FITS image a figure shows.
enum FITSFigureRegion: Codable, Hashable, Sendable {
    /// The whole frame.
    case image
    /// The part of the image on screen.
    case view
    /// 0-based FITS pixels: (x, y) is the corner with the smallest x and y
    /// (bottom-left as displayed).
    case box(x: Double, y: Double, width: Double, height: Double)
    /// A circle on the sky, framed by its square.
    case sky(raDeg: Double, decDeg: Double, radiusDeg: Double)
    /// Around a mark, with room for its label.
    case mark(id: String)

    /// In words, for a proposal.
    var summary: String {
        switch self {
        case .image: return "the whole image"
        case .view: return "the view on screen"
        case .box(let x, let y, let w, let h): return "pixels \(Int(x))…\(Int(x + w)) × \(Int(y))…\(Int(y + h))"
        case .sky(let ra, let dec, let r):
            return "a \(FITSFigureFraming.angle(arcsec: r * 3600)) circle at \(Sexagesimal.searchPair(ra: ra, dec: dec) ?? "\(ra), \(dec)")"
        case .mark(let id): return "mark \(id)"
        }
    }
}

/// What an agent's `export_fits_figure` asks for. Style fields left out
/// are what the person last chose in the Export Figure sheet.
struct FITSFigureRequest: Codable, Sendable, Equatable {
    var scale: Double = 2
    var format: FigureFile.Format = .png
    var region: FITSFigureRegion = .view
    var marks: Bool?
    var annotate: Bool?
    var dark: Bool?

    init(scale: Double = 2, format: FigureFile.Format = .png, region: FITSFigureRegion = .view,
         marks: Bool? = nil, annotate: Bool? = nil, dark: Bool? = nil) {
        self.scale = scale
        self.format = format
        self.region = region
        self.marks = marks
        self.annotate = annotate
        self.dark = dark
    }

    /// A proposal made before regions existed held only `scale`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 2
        format = try c.decodeIfPresent(FigureFile.Format.self, forKey: .format) ?? .png
        region = try c.decodeIfPresent(FITSFigureRegion.self, forKey: .region) ?? .image
        marks = try c.decodeIfPresent(Bool.self, forKey: .marks)
        annotate = try c.decodeIfPresent(Bool.self, forKey: .annotate)
        dark = try c.decodeIfPresent(Bool.self, forKey: .dark)
    }
}

/// Why a figure could not be made.
struct FITSFigureProblem: LocalizedError, Equatable {
    enum Kind: Equatable { case nothingOpen, badRegion, noMark }
    let kind: Kind
    let message: String

    var errorDescription: String? { message }
}

/// A figure ready to be laid out: the part of the rendered image it shows,
/// where that part is, its legend, and the marks on it.
struct FITSFigure {
    let content: CGImage
    /// The part shown, in the display grid (row 0 on top).
    let rect: CGRect
    let legend: [(String, String)]
    let marks: [Mark]
    let placement: FITSMarkPlacement?

    /// Marks on a picture of `rect` drawn `width` points wide.
    func markProjection(width: CGFloat) -> MarkProjection? {
        guard let placement, rect.width > 0 else { return nil }
        let scale = width / rect.width
        let origin = rect.origin
        return placement.projection(pointsPerPixel: scale, rotation: 0) {
            CGPoint(x: ($0.x - origin.x) * scale, y: ($0.y - origin.y) * scale)
        }
    }
}

enum FITSFigureFraming {
    /// A figure is at least this many image pixels on a side (or the whole
    /// image, when that is smaller).
    static let minimumSide: CGFloat = 16
    /// Around a mark: this many times its size across…
    static let aroundMarkFactor: CGFloat = 3
    /// …and at least this many image pixels, so a point or a label has room.
    static let aroundMarkMinimum: CGFloat = 64

    /// An angle for a legend: arcseconds, arcminutes or degrees.
    static func angle(arcsec: Double) -> String {
        if arcsec < 120 { return String(format: "%.1f″", arcsec) }
        if arcsec < 7200 { return String(format: "%.2f′", arcsec / 60) }
        return String(format: "%.2f°", arcsec / 3600)
    }
}

extension FITSViewerModel {

    /// The part of the display grid a figure of `region` shows, clamped to
    /// the image and on whole pixels.
    func figureRect(_ region: FITSFigureRegion, marks: [Mark]) throws(FITSFigureProblem) -> CGRect {
        guard let grid = displayGrid, let placement = markPlacement else {
            throw FITSFigureProblem(kind: .nothingOpen, message: "No FITS image is open in the viewer")
        }
        let whole = CGRect(x: 0, y: 0, width: grid.width, height: grid.height)
        let wanted: CGRect
        switch region {
        case .image:
            return whole
        case .view:
            guard let transform = displayTransform(canvasSize: lastCanvasSize), lastCanvasSize.width > 0 else {
                throw FITSFigureProblem(kind: .nothingOpen, message: "The FITS viewer has not been laid out yet — open it first")
            }
            let (w, h) = (lastCanvasSize.width, lastCanvasSize.height)
            let corners = [CGPoint.zero, CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)].map(transform.screenToImage)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            wanted = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        case .box(let x, let y, let width, let height):
            guard width > 0, height > 0, [x, y, width, height].allSatisfy(\.isFinite) else {
                throw FITSFigureProblem(kind: .badRegion, message: "a box needs a width and height greater than zero")
            }
            // FITS rows go up; the grid's go down.
            wanted = CGRect(x: x, y: Double(grid.height) - y - height, width: width, height: height)
        case .sky(let ra, let dec, let radius):
            guard let wcs, wcs.pixelScaleArcsec > 0 else {
                throw FITSFigureProblem(kind: .badRegion, message: "this image has no WCS, so a sky region has no place on it — use a box or the view")
            }
            guard radius > 0, let centre = placement.displayPoint(Mark.Anchor(space: .sky, x: ra, y: dec)) else {
                throw FITSFigureProblem(kind: .badRegion, message: "that sky position and radius have no place on this image")
            }
            let r = radius * 3600 / wcs.pixelScaleArcsec
            wanted = CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
        case .mark(let id):
            guard let mark = marks.first(where: { $0.id == id }) else {
                throw FITSFigureProblem(kind: .noMark, message: "no mark \"\(id)\" on this image")
            }
            guard let centre = placement.displayPoint(mark.anchor) else {
                throw FITSFigureProblem(kind: .badRegion, message: "mark \(id) has no place on this image")
            }
            let half = mark.extent.flatMap { placement.pixels($0, at: mark.anchor) } ?? .zero
            let side = max(2 * max(half.width, half.height) * FITSFigureFraming.aroundMarkFactor,
                           FITSFigureFraming.aroundMarkMinimum)
            wanted = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        }
        let clipped = wanted.intersection(whole).integral.intersection(whole)
        let least = min(FITSFigureFraming.minimumSide, whole.width, whole.height)
        guard !clipped.isNull, clipped.width >= least, clipped.height >= least else {
            throw FITSFigureProblem(kind: .badRegion, message: "that region is off the image, or too small to show")
        }
        return clipped
    }

    /// The legend for a figure of `rect`: how it was drawn, its size, and —
    /// with a WCS — the region's own centre and field of view.
    func figureLegend(for rect: CGRect) -> [(String, String)] {
        var legend: [(String, String)] = [
            ("Stretch", renderParams.stretch.rawValue),
            ("Cuts", String(format: "%.4g – %.4g", renderParams.minCut, renderParams.maxCut)),
        ]
        guard let grid = displayGrid else { return legend }
        let size = "\(Int(rect.width)) × \(Int(rect.height)) px"
        let whole = rect.width == Double(grid.width) && rect.height == Double(grid.height)
        legend.append(("Size", whole ? size : "\(size) of \(grid.width) × \(grid.height)"))
        if let wcs {
            let centre = grid.pixel(ofDisplay: CGPoint(x: rect.midX, y: rect.midY))
            let sky = wcs.pixelToWorld(x: centre.x, y: centre.y)
            legend.append(("Center", "\(Sexagesimal.readoutHMS(degrees: sky.ra)) \(Sexagesimal.readoutDMS(degrees: sky.dec))"))
            let scale = wcs.pixelScaleArcsec
            legend.append(("Field", "\(FITSFigureFraming.angle(arcsec: rect.width * scale)) × \(FITSFigureFraming.angle(arcsec: rect.height * scale))"))
            legend.append(("Scale", String(format: "%.3g″/px", scale)))
        }
        return legend
    }

    /// Everything a figure of `region` needs, cut from the rendered image.
    func figure(_ region: FITSFigureRegion, marks: [Mark]) throws(FITSFigureProblem) -> FITSFigure {
        guard let rendered = renderedImage, let grid = displayGrid else {
            throw FITSFigureProblem(kind: .nothingOpen, message: "No rendered FITS image is open in the viewer")
        }
        let rect = try figureRect(region, marks: marks)
        // The rendered image is the grid at `k` rendered pixels per image pixel.
        let k = CGFloat(rendered.width) / CGFloat(grid.width)
        let cut = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k).integral
        guard let content = k == 1 && rect.size == CGSize(width: grid.width, height: grid.height) ? rendered : rendered.cropping(to: cut) else {
            throw FITSFigureProblem(kind: .badRegion, message: "that region could not be cut from the image")
        }
        return FITSFigure(content: content, rect: rect, legend: figureLegend(for: rect), marks: marks, placement: markPlacement)
    }
}
