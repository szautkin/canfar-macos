// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import XCTest
@testable import Verbinal

/// get_fits_image: the picture must show what the viewer shows, and its
/// map must point back at the same file pixel.
final class FITSViewSnapshotTests: XCTestCase {

    private let naxis = 100

    /// A dark image with one bright pixel at display (column 30, row 29 from
    /// the top) — FITS array (30, 70).
    private func image() -> CGImage {
        var bytes = [UInt8](repeating: 0, count: naxis * naxis)
        bytes[29 * naxis + 30] = 255
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: naxis, height: naxis, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: naxis,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func brightness(of image: CGImage, u: Int, v: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so picture pixel (u, v from the top) lands on the 1×1 context.
        context.draw(image, in: CGRect(x: -u, y: -(image.height - 1 - v), width: image.width, height: image.height))
        return pixel[0]
    }

    private func check(zoom: Double, rotation: Double, flipX: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let viewport = ViewportTransform(zoom: zoom, rotation: rotation, flipX: flipX, panX: 12, panY: -7,
                                         imageSize: CGSize(width: naxis, height: naxis),
                                         canvasSize: CGSize(width: 400, height: 300))
        let snapshot = try XCTUnwrap(FITSViewSnapshot.make(
            rendered: image(), viewport: viewport, naxis2: naxis, crosshair: nil, maxSide: 200), file: file, line: line)
        XCTAssertEqual(snapshot.image.width, 200, file: file, line: line)

        // Where the viewer puts the bright pixel's centre, in picture pixels.
        let screen = viewport.imageToScreen(CGPoint(x: 30.5, y: 29.5))
        let u = Int((screen.x * 0.5).rounded(.down)), v = Int((screen.y * 0.5).rounded(.down))
        // Within a picture pixel: a pixel centre can sit on a boundary.
        let near = (-1...1).flatMap { du in (-1...1).map { dv in brightness(of: snapshot.image, u: u + du, v: v + dv) } }
        XCTAssertGreaterThan(near.max() ?? 0, 100,
                             "the bright pixel is drawn where the viewer shows it", file: file, line: line)

        let back = snapshot.fitsPixel(u: screen.x * 0.5, v: screen.y * 0.5)
        XCTAssertEqual(back.x, 30, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(back.y, 70, accuracy: 1e-9, file: file, line: line)
    }

    func testPlainView() throws { try check(zoom: 2, rotation: 0, flipX: false) }

    func testRotatedView() throws { try check(zoom: 2, rotation: .pi / 2, flipX: false) }
    func testFlippedView() throws { try check(zoom: 3, rotation: 0.3, flipX: true) }

    /// The encoder may shrink the picture; the map follows it.
    func testTheMapFollowsAShrunkPicture() throws {
        let picture = ViewerPicture(image: image(), caption: [:], toFITSPixel: (a: 0.5, b: 0, c: 1, d: 0, e: -0.5, f: 99))
        let halved = try XCTUnwrap(picture.toFITSPixel(forWidth: 50))
        XCTAssertEqual(halved.a, 1.0)
        XCTAssertEqual(halved.e, -1.0)
        XCTAssertEqual(halved.c, 1)
    }

    func testAnImageTooLargeForTheReplyIsShrunkUntilItFits() throws {
        var noise = [UInt8](repeating: 0, count: 1500 * 1500)
        var seed: UInt32 = 7
        for i in noise.indices { seed = seed &* 1_664_525 &+ 1_013_904_223; noise[i] = UInt8(truncatingIfNeeded: seed >> 24) }
        let big = CGImage(width: 1500, height: 1500, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1500,
                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                          provider: CGDataProvider(data: Data(noise) as CFData)!, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        let encoded = try XCTUnwrap(AgentImageEncoding.encode(big, maxBytes: 200 * 1024))
        XCTAssertLessThanOrEqual(encoded.data.count, 200 * 1024)
    }

    // MARK: - Marks (plan 15 V1, QA M3)

    /// A mark on the image is in the picture, where the viewer draws it.
    @MainActor
    func testTheMarksThePersonSeesAreInThePicture() throws {
        let viewport = ViewportTransform(zoom: 2, rotation: 0, flipX: false, panX: 0, panY: 0,
                                         imageSize: CGSize(width: naxis, height: naxis),
                                         canvasSize: CGSize(width: 400, height: 300))
        let plain = try XCTUnwrap(FITSViewSnapshot.make(rendered: image(), viewport: viewport, naxis2: naxis,
                                                        crosshair: nil, maxSide: 200))
        // Canvas points are the anchor's own numbers here; a circle of radius 40 at (200, 150).
        let projection = MarkProjection(point: { CGPoint(x: $0.x, y: $0.y) },
                                        halfSize: { extent, _ in CGSize(width: extent.halfWidth, height: extent.halfHeight) })
        let circle = Mark(id: "m1", kind: .circle, anchor: .init(space: .imagePixel, x: 200, y: 150), extent: .square(40),
                          author: .agent, createdAt: Date(timeIntervalSince1970: 0))

        let marked = plain.drawingMarks([circle], projection: projection, canvas: viewport.canvasSize)

        XCTAssertEqual(marked.image.width, plain.image.width)
        XCTAssertEqual(marked.image.height, plain.image.height)
        // The circle's right edge: canvas (240, 150) → picture (120, 75).
        func colour(_ image: CGImage, _ u: Int, _ v: Int) -> Int {
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -u, y: -(image.height - 1 - v), width: image.width, height: image.height))
            return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])
        }
        let edge = (-2...2).flatMap { du in (-2...2).map { dv in colour(marked.image, 120 + du, 75 + dv) } }
        let before = (-2...2).flatMap { du in (-2...2).map { dv in colour(plain.image, 120 + du, 75 + dv) } }
        XCTAssertGreaterThan(edge.max() ?? 0, (before.max() ?? 0) + 150, "the mark is drawn")
        XCTAssertEqual(brightness(of: marked.image, u: 100, v: 20), brightness(of: plain.image, u: 100, v: 20),
                       "and the rest is the picture as it was")
        XCTAssertTrue(plain.drawingMarks([], projection: projection, canvas: viewport.canvasSize).image === plain.image)
    }
}
