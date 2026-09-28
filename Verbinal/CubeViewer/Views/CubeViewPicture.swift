// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// What the Cube Viewer shows, as one picture for `get_cube_image`: the
/// slice or the volume on the viewer's own background, its marks as a
/// figure draws them, and the probed spectrum when there is one.
///
/// It returned the raw slice (53×55 for the Europa cube, whatever
/// `maxPixels` asked), a volume on white while the viewer said dark, and
/// no spectrum (QA M4, L11).
struct CubeViewPicture: View {
    let model: CubeViewerModel
    let content: CGImage
    let size: CGSize
    let marks: [Mark]

    /// The picture, its longer side `maxSide` (more when the spectrum is
    /// under it); nil before the viewer has drawn.
    @MainActor
    static func render(model: CubeViewerModel, marks: [Mark], maxSide: Int) -> CGImage? {
        let content: CGImage?
        let size: CGSize
        switch model.viewMode {
        case .slice:
            guard model.nx > 0, model.ny > 0 else { return nil }
            content = model.sliceImage
            let side = CGFloat(maxSide), aspect = CGFloat(model.ny) / CGFloat(model.nx)
            size = aspect <= 1 ? CGSize(width: side, height: (side * aspect).rounded())
                               : CGSize(width: (side / aspect).rounded(), height: side)
        case .volume:
            size = CGSize(width: maxSide, height: maxSide * 3 / 4)
            content = model.volumeSnapshot?(Int(size.width), Int(size.height), model.background.rgba)
        }
        guard let content else { return nil }
        let renderer = ImageRenderer(content: CubeViewPicture(model: model, content: content, size: size, marks: marks))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Whether the picture carries the spectrum.
    @MainActor
    static func showsSpectrum(_ model: CubeViewerModel) -> Bool {
        model.probePoint != nil && model.probeSpectrum?.contains(where: \.isFinite) == true
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(decorative: content, scale: 1)
                .resizable()
                .interpolation(model.viewMode == .slice ? .none : .high)
                .frame(width: size.width, height: size.height)
                .overlay {
                    if !marks.isEmpty, let projection = model.figureMarkProjection(size: size) {
                        MarkOverlay(marks: marks, selectedID: nil, projection: projection, showsGrips: false)
                    }
                }
            if Self.showsSpectrum(model), let spectrum = model.probeSpectrum, let point = model.probePoint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spectrum @ (\(point.x), \(point.y))").font(.caption.bold())
                    CubeSpectrumView(spectrum: spectrum, channel: model.channel) { _ in }
                        .frame(height: 90)
                }
                .padding(10)
                .frame(width: size.width, alignment: .leading)
            }
        }
        .background(model.background.color)
        .environment(\.colorScheme, model.background == .light ? .light : .dark)
    }
}
