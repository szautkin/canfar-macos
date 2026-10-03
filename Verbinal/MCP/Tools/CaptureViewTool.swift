// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import VerbinalKit

/// A window as the person sees it.
///
/// Drawing the window's layers ourselves (plan 15 P1) left out what the
/// window server composites — materials, vibrancy and the text on them —
/// so the Portal header and the Cube side panel came out as grey bars and
/// the spectrum's axes blank (plan 19 C1, QA N16). The window server's own
/// picture of Verbinal's window needs no Screen Recording permission: the
/// app's windows are its own. The layers are the fallback, for a window
/// the window server has no picture of.
@MainActor
enum WindowCapture {
    /// Verbinal's frontmost visible window that can be a main window — the
    /// main window, or Settings when it is in front.
    static var frontWindow: NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }
    }

    /// What the person sees of `window`: its sheet when one is open.
    static func shown(_ window: NSWindow) -> NSWindow {
        window.attachedSheet.map(shown) ?? window
    }

    /// The hint panels over `window`: what the person sees on it — rings,
    /// bubbles, the dimming (plan 30 C).
    static func hintPanels(over window: NSWindow) -> [NSWindow] {
        (window.childWindows ?? []).filter {
            $0.isVisible && PointableID.Window(identifier: $0.identifier?.rawValue) == .hints
        }
    }

    /// `window` as the window server composites it, with the hints drawn
    /// over it, its longer side at most `maxSide` pixels; nil when it has no
    /// picture of it (off screen).
    static func composited(_ window: NSWindow, maxSide: Int) -> CGImage? {
        guard let image = picture(of: window) else { return nil }
        let panels = hintPanels(over: window).compactMap { panel in picture(of: panel).map { (frame: panel.frame, image: $0) } }
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        guard scale < 1 || !panels.isEmpty else { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Each hint panel where it lies over the window: screen points, bottom-up as the context is.
        let perPoint = CGFloat(width) / window.frame.width
        for panel in panels {
            context.draw(panel.image, in: CGRect(x: (panel.frame.minX - window.frame.minX) * perPoint,
                                                 y: (panel.frame.minY - window.frame.minY) * perPoint,
                                                 width: panel.frame.width * perPoint, height: panel.frame.height * perPoint))
        }
        return context.makeImage()
    }

    /// The window server's picture of one window; nil when it has none (off screen).
    private static func picture(of window: NSWindow) -> CGImage? {
        guard window.isVisible, window.windowNumber > 0,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              image.width > 1, image.height > 1 else { return nil }
        return image
    }

    /// `view` drawn upright from its layers, its longer side at most `maxSide` pixels.
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
            description: "See Verbinal's window as the person sees it — whatever screen, sheet or Settings section is in front — as a picture, with a caption naming the window, its size and the mode. For checking what the app shows (a layout, a message, a state) rather than asking. The picture is the window as composited on screen (`drawnBy: \"screen\"`), with the hints shown over it (`hints: true`) — rings, bubbles and the dimming, as the person sees them; for a window not on screen it is drawn from its layers (`drawnBy: \"layers\"`), where a material's text can be missing and a Metal-drawn view blank — get_fits_image and get_cube_image draw the viewers' images. Capped to stay under the client's response limit.",
            schema: ViewerImageArgs.schema), picture: picture)
    }
}
