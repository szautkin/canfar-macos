// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import UniformTypeIdentifiers
import VerbinalKit

/// Cube on iPhone and iPad: review a data cube, and verify it (plan 47 phase
/// 5). A channel's slice, the channels under the thumb, a spaxel's spectrum,
/// moment 0 for "did the line show up", and — where the device has the
/// memory — the volume, ray-marched by the Mac's renderer.
struct iOSCubeViewer: View {
    var host: CubeTabHostModel
    var onOpen: () -> Void
    var onShowFile: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case slice, moment, volume
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .slice: return "Slice"
            case .moment: return "Moment 0"
            case .volume: return "Volume"
            }
        }
    }

    @State private var mode: Mode = .slice
    @State private var chromeHidden = false
    @State private var showControls = false
    @State private var controlsSection: iOSCubeControls.Section = .display
    @State private var moment: (cube: UUID, image: CGImage)?
    @State private var momentProgress: Double?

    /// The volume needs memory: an iPad, or an iPhone with 6 GB or more (decision D5).
    static var volumeAllowed: Bool {
        UIDevice.current.userInterfaceIdiom == .pad || ProcessInfo.processInfo.physicalMemory >= 5_500_000_000
    }

    private var modes: [Mode] { Self.volumeAllowed ? Mode.allCases : [.slice, .moment] }

    var body: some View {
        let model = host.activeTab
        VStack(spacing: 0) {
            if !chromeHidden && model.hasData {
                Picker("", selection: $mode) {
                    ForEach(modes) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            ZStack {
                switch mode {
                case .volume where model.volumeData != nil:
                    iOSCubeVolumeView(model: model)
                        .overlay(alignment: .top) {
                            if let error = model.volumeRenderError {
                                Text(verbatim: error).font(.caption).padding(8).background(.regularMaterial, in: Capsule()).padding()
                            }
                        }
                default:
                    iOSCubeSliceCanvas(model: model,
                                       moment: mode == .moment ? moment.flatMap { $0.cube == model.id ? $0.image : nil } : nil,
                                       chromeHidden: $chromeHidden) {
                        controlsSection = .spectrum
                        showControls = true
                    }
                    if mode == .moment, moment?.cube != model.id {
                        momentStatus
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !chromeHidden, mode == .slice, let readout = model.skyReadout {
                    Text(verbatim: "\(readout.lon) \(readout.lat)  \(model.cursorValue)")
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
            if !chromeHidden && model.hasData && mode != .moment {
                iOSChannelScrubber(model: model)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .navigationTitle(model.fileName.isEmpty ? String(localized: "Cube") : model.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filesMenu }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: iOSCubePicture(model: model, moment: mode == .moment ? moment?.image : nil),
                          preview: SharePreview(model.fileName, image: Image(systemName: "cube"))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(model.sliceImage == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { controlsSection = .display; showControls = true } label: {
                    Label("Adjust", systemImage: "slider.horizontal.3")
                }
            }
        }
        .toolbar(chromeHidden ? .hidden : .automatic, for: .navigationBar)
        .toolbar(chromeHidden ? .hidden : .automatic, for: .tabBar)
        .statusBarHidden(chromeHidden)
        .sheet(isPresented: $showControls) {
            iOSCubeControls(model: model, section: $controlsSection)
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
                .presentationDragIndicator(.visible)
        }
        .onChange(of: mode) { _, newMode in
            model.viewMode = newMode == .volume ? .volume : .slice
            if newMode == .slice { model.requestSliceRender() }
        }
        .task(id: "\(model.id)-\(mode)-\(model.hasData)") {
            guard mode == .moment, model.hasData, moment?.cube != model.id else { return }
            await makeMoment(model)
        }
    }

    // MARK: - Moment 0

    private var momentStatus: some View {
        VStack(spacing: 8) {
            ProgressView(value: momentProgress ?? 0).frame(width: 180).tint(.white)
            Text("Summing the channels…").font(.caption).foregroundStyle(.white.opacity(0.8))
        }
    }

    /// Sums the channels a plane at a time, then draws the map with the
    /// slice's colormap and a first-look cut.
    private func makeMoment(_ model: CubeViewerModel) async {
        guard let cube = model.cube else { return }
        let nz = model.nz, spaxels = model.nx * model.ny, width = model.nx, height = model.ny
        let step = model.wcs?.spectral.cdelt ?? 1
        var sum = CubeMoment0(spaxels: spaxels)
        momentProgress = 0
        for channel in 0..<nz {
            guard !Task.isCancelled, let plane = try? await cube.plane(channel), plane.count == spaxels else { return }
            sum.add(plane)
            if channel % 8 == 0 { momentProgress = Double(channel + 1) / Double(nz) }
        }
        let map = sum.map(channelWidth: step)
        let colormap = model.colormap, stretch = model.stretch
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let cut = LinearCut.firstLook(samples: FITSVerify.evenSample(map, limit: 1_000_000))
            return FITSRenderEngine.render(pixels: map, width: width, height: height,
                                           params: FITSRenderParams(minCut: cut.lo, maxCut: cut.hi, stretch: stretch, colormap: colormap))
        }.value
        momentProgress = nil
        if let image { moment = (model.id, image) }
    }

    // MARK: - Files

    private var filesMenu: some View {
        Menu {
            ForEach(Array(host.tabs.enumerated()), id: \.element.id) { index, tab in
                if tab.hasData {
                    Button {
                        host.activeTabIndex = index
                    } label: {
                        if index == host.activeTabIndex { Label(tab.fileName, systemImage: "checkmark") } else { Text(tab.fileName) }
                    }
                }
            }
            Divider()
            Button { onOpen() } label: { Label("Open…", systemImage: "folder") }
            Button { onShowFile() } label: { Label("File Page", systemImage: "doc.text.magnifyingglass") }
        } label: {
            Label("Files", systemImage: "doc.on.doc")
        }
    }
}

/// A picture of the slice (or the moment map) with its channel, made when it
/// is shared.
struct iOSCubePicture: Transferable {
    let model: CubeViewerModel
    let moment: CGImage?

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { picture in try await picture.png() }
    }

    @MainActor func png() throws -> Data {
        guard let image = moment ?? model.sliceImage else { throw CocoaError(.fileWriteUnknown) }
        let caption = moment != nil
            ? String(localized: "Moment 0")
            : [model.spectralReadout?.primary, model.spectralReadout?.secondary, "ch \(model.channel)"].compactMap { $0 }.joined(separator: " · ")
        let view = VStack(spacing: 0) {
            Image(decorative: image, scale: 1).resizable().interpolation(.none)
                .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
                .frame(width: 900)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.fileName).font(.caption.weight(.semibold))
                Text(verbatim: "\(caption) · \(model.stretch.rawValue) · \(model.colormap.rawValue) · Verbinal").font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(width: 900, alignment: .leading)
            .padding(8)
        }
        .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
