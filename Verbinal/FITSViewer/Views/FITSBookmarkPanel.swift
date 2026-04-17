// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct FITSBookmarkPanel: View {
    var model: FITSViewerModel
    var store: BookmarkStore

    @State private var labelText: String = ""
    @Environment(\.fitsToast) private var toast

    private var bookmarks: [CoordinateBookmark] {
        guard let path = model.fileURL?.path else { return store.bookmarks }
        return store.bookmarks(for: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Bookmarks")
                    .font(.caption.bold())
                Spacer()
                // Save current crosshair
                Button {
                    guard !model.crosshairRA.isEmpty,
                          let wcs = model.wcs,
                          let pixel = model.crosshairPixel,
                          let hdu = model.selectedHDU else { return }
                    let fitsY = FITSViewerModel.displayToFITSY(pixel.y, naxis2: hdu.header.naxis2)
                    let (ra, dec) = wcs.pixelToWorld(x: pixel.x, y: fitsY)
                    let resolvedLabel = labelText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "\(model.crosshairRA) \(model.crosshairDec)"
                        : labelText.trimmingCharacters(in: .whitespaces)
                    let bookmark = CoordinateBookmark(
                        label: resolvedLabel, ra: ra, dec: dec,
                        sourceFilePath: model.fileURL?.path ?? ""
                    )
                    store.save(bookmark)
                    labelText = ""
                    toast?.show(String(localized: "Bookmark saved"))
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(model.crosshairRA.isEmpty)
                .help("Save current crosshair position")
            }
            .padding(.horizontal, 8)

            if model.crosshairPixel != nil {
                TextField("Label (optional)", text: $labelText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                    .padding(.horizontal, 8)
            }

            if bookmarks.isEmpty {
                Text("No bookmarks")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            } else {
                List(bookmarks) { bookmark in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bookmark.label)
                            .font(.caption2.bold())
                            .lineLimit(1)
                        Text(bookmark.formattedCoords)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Go to this coordinate
                        model.goToCoordinate(ra: bookmark.ra, dec: bookmark.dec)
                    }
                    .contextMenu {
                        Button("Go To") {
                            model.goToCoordinate(ra: bookmark.ra, dec: bookmark.dec)
                        }
                        Button("Delete", role: .destructive) {
                            store.delete(bookmark)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 150)
            }
        }
    }
}
