// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import UniformTypeIdentifiers
import VerbinalKit

/// FITS on iPhone and iPad: review an image, and verify it (plan 47 phase 4).
/// The image fills the screen; a tap hides the chrome. The readout says
/// where the crosshair is; Adjust opens the controls in a sheet that leaves
/// the image usable; Share sends a picture of the view; with two files open,
/// holding Compare shows the other, aligned by WCS.
struct iOSFITSViewer: View {
    var host: FITSTabHostModel
    /// Open another file, or show the page of the one open.
    var onOpen: () -> Void
    var onShowFile: () -> Void
    /// The last open image was closed.
    var onClosedAll: () -> Void

    @State private var chromeHidden = false
    @State private var showControls = false
    @State private var probe: CGPoint?
    @State private var copied = false

    var body: some View {
        if let model = host.activeTab {
            iOSFITSCanvas(model: model, host: host, chromeHidden: $chromeHidden, probe: $probe)
                .ignoresSafeArea(edges: chromeHidden ? .all : [])
                .overlay(alignment: .bottom) {
                    if !chromeHidden { readout(model) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !chromeHidden, host.tabs.count > 1 { compareButton }
                }
                .navigationTitle(model.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: iOSFITSPicture(model: model),
                                  preview: SharePreview(model.displayName, image: Image(systemName: "photo"))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .disabled(model.renderedImage == nil)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showControls = true } label: { Label("Adjust", systemImage: "slider.horizontal.3") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { close() } label: { Label("Close", systemImage: "xmark") }
                    }
                }
                .toolbarTitleMenu { titleMenu }
                .toolbar(chromeHidden ? .hidden : .automatic, for: .navigationBar)
                .toolbar(chromeHidden ? .hidden : .automatic, for: .tabBar)
                .statusBarHidden(chromeHidden)
                .sheet(isPresented: $showControls) {
                    iOSFITSControls(model: model)
                        .presentationDetents([.fraction(0.45), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
                        .presentationDragIndicator(.visible)
                }
        }
    }

    // MARK: - Readout

    /// Where the crosshair is: its sky position and value; a tap copies them.
    @ViewBuilder
    private func readout(_ model: FITSViewerModel) -> some View {
        let reading = probe != nil && !model.cursorPixelValue.isEmpty
            ? (model.cursorRA, model.cursorDec, model.cursorPixelValue)
            : (model.crosshairRA, model.crosshairDec, model.crosshairValue)
        if !reading.2.isEmpty || !reading.0.isEmpty {
            Button {
                copied = PlatformClipboard.copy([reading.0, reading.1].filter { !$0.isEmpty }.joined(separator: " "))
            } label: {
                HStack(spacing: 8) {
                    if !reading.0.isEmpty { Text(verbatim: "\(reading.0) \(reading.1)") }
                    if !reading.2.isEmpty { Text(verbatim: reading.2).fontWeight(.semibold) }
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .font(.footnote.monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
            .accessibilityHint(Text("Copies the coordinates"))
            .sensoryFeedback(.success, trigger: copied) { _, new in new }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }

    // MARK: - Files

    /// The file name's menu (the title's): the open images, Open…, the file's page.
    @ViewBuilder
    private var titleMenu: some View {
        ForEach(Array(host.tabs.enumerated()), id: \.element.id) { index, tab in
            Button {
                host.activeTabIndex = index
            } label: {
                if index == host.activeTabIndex {
                    Label(tab.displayName, systemImage: "checkmark")
                } else {
                    Text(tab.displayName)
                }
            }
        }
        Divider()
        Button { onOpen() } label: { Label("Open…", systemImage: "folder") }
        Button { onShowFile() } label: { Label("File Page", systemImage: "doc.text.magnifyingglass") }
    }

    /// Closes the image shown; the last one brings back Open.
    private func close() {
        host.stopBlink()
        host.closeActiveTab()
        if host.tabs.isEmpty { onClosedAll() }
    }

    // MARK: - Compare

    /// Hold to see the other open image, aligned by WCS (the Mac's blink).
    private var compareButton: some View {
        Image(systemName: host.isBlinking ? "square.on.square.fill" : "square.on.square")
            .font(.title3)
            .frame(width: 48, height: 48)
            .background(.regularMaterial, in: Circle())
            .padding(.trailing, 16)
            .padding(.bottom, 60)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60) {
            } onPressingChanged: { pressing in
                pressing ? startCompare() : host.stopBlink()
            }
            .sensoryFeedback(.impact(weight: .light), trigger: host.isBlinking)
            .accessibilityLabel(Text("Compare"))
            .accessibilityHint(Text("Hold to see the other open image"))
            .accessibilityAction { host.isBlinking ? host.stopBlink() : startCompare() }
    }

    private func startCompare() {
        let active = host.activeTabIndex
        let other = active == 0 ? 1 : active - 1
        guard other < host.tabs.count else { return }
        host.startBlink(tabA: active, tabB: other)
        host.showBlinkB()
    }
}

/// A picture of the view, made when it is shared: the image as it is on
/// screen, and a line under it — the file, where the crosshair is, how it is
/// shown (plan 47 4.5).
struct iOSFITSPicture: Transferable {
    let model: FITSViewerModel

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { picture in try await picture.png() }
    }

    @MainActor func png() throws -> Data {
        let renderer = ImageRenderer(content: iOSFITSPictureView(model: model))
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

private struct iOSFITSPictureView: View {
    var model: FITSViewerModel

    var body: some View {
        let canvas = model.lastCanvasSize
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = model.renderedImage, let size = model.imageSize {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(model.viewport.zoom >= 2 ? .none : .medium)
                        .frame(width: size.width * model.viewport.zoom, height: size.height * model.viewport.zoom)
                        .scaleEffect(x: model.viewport.flipX ? -1 : 1, y: 1)
                        .rotationEffect(.radians(model.viewport.rotation))
                        .position(x: canvas.width / 2 + model.viewport.panX, y: canvas.height / 2 + model.viewport.panY)
                    if let crosshair = model.crosshairPixel {
                        let point = model.imageToScreen(crosshair, imgSize: size, canvasSize: canvas)
                        Circle().stroke(Color.green, lineWidth: 1.5).frame(width: 18, height: 18).position(point)
                    }
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.displayName).font(.caption.weight(.semibold))
                Text(verbatim: caption).font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.white)
            .frame(width: canvas.width, alignment: .leading)
            .padding(8)
            .background(Color.black)
        }
    }

    private var caption: String {
        var parts: [String] = []
        if !model.crosshairRA.isEmpty { parts.append("\(model.crosshairRA) \(model.crosshairDec)") }
        if !model.crosshairValue.isEmpty { parts.append(model.crosshairValue) }
        parts.append("\(model.renderParams.stretch.rawValue) · \(model.renderParams.colormap.rawValue)")
        parts.append("Verbinal")
        return parts.joined(separator: " · ")
    }
}
