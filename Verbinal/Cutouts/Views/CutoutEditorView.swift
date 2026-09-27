// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// The cutout editor: which file, the region on its footprint, a band for a
/// cube, what the rules say as you type, and how large it will be.
struct CutoutEditorView: View {
    @Bindable var model: CutoutEditorModel
    /// Downloads the cutout; the editor closes.
    let download: (CutoutSpec) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cut Out").font(.title2.bold())
                Text(model.details.targetName.isEmpty ? model.publisherID : model.details.targetName)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            switch model.phase {
            case .loading:
                ProgressView("Asking CADC what it can cut…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            case .unavailable(let problems):
                VStack(alignment: .leading, spacing: 6) {
                    Label("CADC offers no cutouts of this observation's files.", systemImage: "scissors")
                        .font(.callout)
                    ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            case .ready:
                editor
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download Cutout") {
                    guard let spec = model.acceptedSpec else { return }
                    download(spec)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.acceptedSpec == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { if model.phase == .loading { await model.load() } }
    }

    // MARK: - The editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.sources.count > 1 {
                Picker("File", selection: $model.sourceIndex) {
                    ForEach(model.sources.indices, id: \.self) { i in
                        Text(model.label(of: model.sources[i])).tag(i)
                    }
                }
            }
            if let why = model.source?.unavailable {
                Label(why, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 16) {
                CutoutSketch(footprint: model.source?.file.footprint, region: sketchRegion)
                    .frame(width: 170, height: 170)
                    .accessibilityLabel(Text("The file's footprint and the region to cut"))
                fields
            }
            issues
        }
    }

    private var sketchRegion: SkyRegion? {
        if case .success(let spec) = model.spec { return spec.region }
        return nil
    }

    private var fields: some View {
        Form {
            if model.polygon == nil {
                Picker("Shape", selection: $model.shape) {
                    Text("Circle").tag(SkyRegion.Shape.circle)
                    Text("Box").tag(SkyRegion.Shape.box)
                }
                .pickerStyle(.segmented)
                TextField("RA", text: $model.raText, prompt: Text("deg or hh:mm:ss"))
                TextField("Dec", text: $model.decText, prompt: Text("deg or ±dd:mm:ss"))
                if model.shape == .box {
                    TextField("Width (′)", text: $model.widthArcmin)
                    TextField("Height (′)", text: $model.heightArcmin)
                } else {
                    TextField("Radius (′)", text: $model.radiusArcmin)
                }
            } else if let polygon = model.polygon {
                LabeledContent("Region", value: polygon.summary)
            }
            if model.imageNames.count > 1 {
                LabeledContent("Images") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.imageNames, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { model.chosenImages.contains(name) },
                                set: { if $0 { model.chosenImages.insert(name) } else { model.chosenImages.remove(name) } }))
                        }
                        Text("None ticked: every image the region falls on")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if model.takesBand {
                TextField("Shortest (nm)", text: $model.bandMinNM, prompt: Text("any"))
                TextField("Longest (nm)", text: $model.bandMaxNM, prompt: Text("any"))
            }
        }
        .formStyle(.columns)
    }

    @ViewBuilder
    private var issues: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.spec {
            case .failure(let problem) where !problem.text.isEmpty:
                Label(problem.text, systemImage: "character.cursor.ibeam").foregroundStyle(.secondary)
            case .success(let spec):
                Text(spec.summary).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(model.check?.errors ?? [], id: \.self) {
                    Label($0.localizedMessage, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                ForEach(model.check?.warnings ?? [], id: \.self) {
                    Label($0.localizedMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let bytes = model.estimatedBytes {
                    let whole = model.source?.wholeFileBytes.map { SharedFormatters.bytes($0) }
                    Text(whole.map { String(localized: "About \(SharedFormatters.bytes(bytes)) of \($0)") }
                         ?? String(localized: "About \(SharedFormatters.bytes(bytes))"))
                        .font(.callout)
                }
            default:
                EmptyView()
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The file's footprint with the region on it, on the tangent plane about
/// the footprint — east to the left, as on the sky.
struct CutoutSketch: View {
    let footprint: SkyRegion?
    let region: SkyRegion?

    var body: some View {
        Canvas { context, size in
            let shapes = Self.layout(footprint: footprint?.outline() ?? [], region: region?.outline() ?? [], in: size)
            if shapes.footprint.count > 2 {
                let path = Self.path(shapes.footprint)
                context.fill(path, with: .color(.secondary.opacity(0.15)))
                context.stroke(path, with: .color(.secondary), lineWidth: 1)
            }
            if shapes.region.count > 2 {
                context.stroke(Self.path(shapes.region), with: .color(.accentColor), lineWidth: 2)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// Both outlines on the plane about the footprint's centre, fitted
    /// together into `size` with a margin.
    static func layout(footprint: [SkyPoint], region: [SkyPoint], in size: CGSize) -> (footprint: [CGPoint], region: [CGPoint]) {
        let all = footprint + region
        guard !all.isEmpty else { return ([], []) }
        let centre = SkyGeometry.centroid(footprint.isEmpty ? region : footprint)
        func flat(_ points: [SkyPoint]) -> [CGPoint] {
            points.compactMap { SkyGeometry.project($0, about: centre).map { CGPoint(x: -$0.x, y: -$0.y) } }
        }
        let f = flat(footprint), r = flat(region), both = f + r
        guard let minX = both.map(\.x).min(), let maxX = both.map(\.x).max(),
              let minY = both.map(\.y).min(), let maxY = both.map(\.y).max() else { return ([], []) }
        let margin = 10.0
        let scale = min((size.width - 2 * margin) / max(maxX - minX, 1e-12), (size.height - 2 * margin) / max(maxY - minY, 1e-12))
        let offset = CGPoint(x: (size.width - (maxX - minX) * scale) / 2, y: (size.height - (maxY - minY) * scale) / 2)
        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: offset.x + (p.x - minX) * scale, y: offset.y + (p.y - minY) * scale) }
        return (f.map(place), r.map(place))
    }
}
