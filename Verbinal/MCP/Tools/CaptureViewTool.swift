// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import VerbinalKit

/// A window as the person sees it, drawn from its layers — how the Portal
/// layout was checked offscreen (plan 15 P1), where `ImageRenderer` and
/// `cacheDisplay` drew nothing for it. A Metal-drawn view may come out
/// blank; the viewers' own picture tools draw those.
@MainActor
enum WindowCapture {
    /// Verbinal's frontmost visible window that can be a main window — the
    /// main window, or Settings when it is in front.
    static var frontWindow: NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }
    }

    /// `view` drawn upright, its longer side at most `maxSide` pixels.
    static func image(of view: NSView, maxSide: Int) -> CGImage? {
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1, let layer = view.layer else { return nil }
        let backing = view.window?.backingScaleFactor ?? 2
        let scale = min(backing, CGFloat(maxSide) / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // A layer tree renders top-down into a bottom-up bitmap: turn it over.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        return context.makeImage()
    }
}

extension ViewerImageTool {
    /// `capture_view` — the shape the viewers' pictures take, for the window.
    static func window(picture: @escaping @Sendable (Int) async throws -> ViewerPicture) -> Self {
        Self(definition: AIToolDefinition.withStaticSchema(
            name: "capture_view",
            description: "See Verbinal's window as the person sees it — whatever screen, sheet or Settings section is in front — as a picture, with a caption naming the window, its size and the mode. For checking what the app shows (a layout, a message, a state) rather than asking. Drawn from the window's layers: a Metal-drawn view can come out blank, so use get_fits_image and get_cube_image for the viewers' images. Capped to stay under the client's response limit.",
            schema: ViewerImageArgs.schema), picture: picture)
    }
}
