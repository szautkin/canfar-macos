// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation
import VerbinalKit
import MCPCore

/// Arguments shared by the viewer picture tools.
struct ViewerImageArgs: Decodable, Sendable {
    /// The picture's longer side, in pixels.
    var maxPixels: Int?

    var side: Int { min(max(maxPixels ?? 1024, 256), 2048) }

    static let schema = #"""
    {
      "type": "object",
      "properties": {
        "maxPixels": { "type": "integer", "minimum": 256, "maximum": 2048, "description": "Longer side of the picture (default 1024)." }
      },
      "additionalProperties": false
    }
    """#
}

/// A picture of a viewer for an agent: the image block, and a caption with
/// what it shows and how to point into it.
struct ViewerPicture: Sendable {
    typealias Affine = (a: Double, b: Double, c: Double, d: Double, e: Double, f: Double)

    let image: CGImage
    /// JSON-encodable facts about the view, placed in the caption.
    let caption: [String: JSONValue]
    /// Picture pixel → file pixel, for `image` at its own size.
    var toFITSPixel: Affine?

    /// The map for a copy of `image` resized to `width` — the encoder may
    /// shrink the picture to fit the reply, and the map must follow it.
    func toFITSPixel(forWidth width: Int) -> Affine? {
        guard let m = toFITSPixel, width > 0 else { return nil }
        let k = Double(image.width) / Double(width)
        return (m.a * k, m.b * k, m.c, m.d * k, m.e * k, m.f)
    }
}

/// `get_fits_image` / `get_cube_image` — the one shape both take.
struct ViewerImageTool: AITool {
    static let verbClass: VerbClass = .read
    static let agentSafe: Bool = true

    let definition: AIToolDefinition
    let picture: @Sendable (_ maxSide: Int) async throws -> ViewerPicture

    static func fits(picture: @escaping @Sendable (Int) async throws -> ViewerPicture) -> Self {
        Self(definition: AIToolDefinition.withStaticSchema(
            name: "get_fits_image",
            description: "See what the FITS Viewer shows: a picture of its canvas as the user sees it — zoom, pan, rotation, colormap, stretch and crosshair — with a caption giving the file, HDU and view, and `toFITSPixel`, the exact map from a picture pixel (u right, v down, from the top-left) to the file's 0-based FITS pixel: x = a·u + b·v + c, y = d·u + e·v + f. Point at something you see by converting it, then use probe_fits_pixel or set_fits_view. Capped to stay under the client's response limit.",
            schema: ViewerImageArgs.schema), picture: picture)
    }

    static func cube(picture: @escaping @Sendable (Int) async throws -> ViewerPicture) -> Self {
        Self(definition: AIToolDefinition.withStaticSchema(
            name: "get_cube_image",
            description: "See what the Cube Viewer shows: a picture of the volume or slice on screen, with a caption giving the file, channel, view mode and colormap. Capped to stay under the client's response limit.",
            schema: ViewerImageArgs.schema), picture: picture)
    }

    func invoke(arguments: Data, context: AIToolContext) async -> ToolResult {
        let args: ViewerImageArgs
        do {
            args = try JSONDecoder().decode(ViewerImageArgs.self, from: arguments.isEmpty ? Data("{}".utf8) : arguments)
        } catch {
            return .failed(.invalidArgument("\(error)"))
        }
        do {
            let picture = try await picture(args.side)
            guard let encoded = AgentImageEncoding.encode(picture.image) else {
                return .failed(.backendError("the picture could not be made small enough to send"))
            }
            var caption = picture.caption
            caption["picture"] = .object(["width": .int(encoded.width), "height": .int(encoded.height),
                                          "format": .string(encoded.mimeType)])
            if let m = picture.toFITSPixel(forWidth: encoded.width) {
                caption["toFITSPixel"] = .object([
                    "a": .double(m.a), "b": .double(m.b), "c": .double(m.c),
                    "d": .double(m.d), "e": .double(m.e), "f": .double(m.f),
                    "formula": .string("x = a*u + b*v + c; y = d*u + e*v + f (0-based FITS pixel; u right, v down from the picture's top-left)"),
                ])
            }
            let captionText = String(decoding: try JSONEncoder().encode(JSONValue.object(caption)), as: UTF8.self)
            return .image(data: encoded.data, mimeType: encoded.mimeType, caption: captionText)
        } catch let failure as ToolFailureReason {
            return .failed(failure)
        } catch {
            return .failed(.backendError("\(error)"))
        }
    }
}
