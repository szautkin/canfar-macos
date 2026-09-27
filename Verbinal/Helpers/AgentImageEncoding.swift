// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes a picture for an agent under a byte cap. MCP clients reject a
/// response much over 1 MB and the image travels as base64 (4/3 larger),
/// so: PNG if it fits, else JPEG, else smaller — never a refused reply.
enum AgentImageEncoding {
    /// Raw bytes whose base64, with a caption, stays under ~1 MB.
    static let defaultMaxBytes = 680 * 1024

    struct Encoded {
        let data: Data
        let mimeType: String
        let width: Int
        let height: Int
    }

    static func encode(_ image: CGImage, maxBytes: Int = defaultMaxBytes) -> Encoded? {
        var current = image
        while true {
            if let png = data(current, type: .png, quality: nil), png.count <= maxBytes {
                return Encoded(data: png, mimeType: "image/png", width: current.width, height: current.height)
            }
            if let jpeg = data(current, type: .jpeg, quality: 0.85), jpeg.count <= maxBytes {
                return Encoded(data: jpeg, mimeType: "image/jpeg", width: current.width, height: current.height)
            }
            guard min(current.width, current.height) > 128, let smaller = scaled(current, by: 0.75) else { return nil }
            current = smaller
        }
    }

    /// `image` shrunk so its longer side is at most `maxSide`.
    static func fitting(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        return scaled(image, by: Double(maxSide) / Double(longest)) ?? image
    }

    private static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func data(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
