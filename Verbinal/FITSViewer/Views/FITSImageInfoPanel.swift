// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import VerbinalKit

/// Compact observational and WCS summary shown above the raw FITS cards.
struct FITSImageInfoPanel: View {
    var model: FITSViewerModel

    private var header: FITSHeader? { model.selectedHDU?.header }
    private var dimensions: String {
        guard let h = header else { return "—" }
        let depth = h.int("NAXIS3")
        return depth > 0 ? "\(h.naxis1) × \(h.naxis2) × \(depth)" : "\(h.naxis1) × \(h.naxis2)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Image Info").font(.subheadline.weight(.semibold))
            row("Dimensions", dimensions)
            row("Pixel range", String(format: "%.5g … %.5g", model.pixelMin, model.pixelMax))
            if let wcs = model.wcs {
                row("WCS", String(localized: wcs.isValid ? "Available" : "Approximate"))
                row("Scale", String(format: "%.3g″/px", wcs.pixelScaleArcsec))
                row("Center", String(format: "%.5f°, %+.5f°", wcs.crval1, wcs.crval2))
                row("Orientation", String(format: "%.1f°", wcs.northAngle))
                let fov = Double(header?.naxis1 ?? 0) * wcs.pixelScaleArcsec / 60
                row("Field of view", String(format: "%.3g′", fov))
            } else {
                row("WCS", String(localized: "Unavailable"))
            }
            metadataRows
        }
        .font(.caption2)
        .padding(8)
    }

    @ViewBuilder private var metadataRows: some View {
        if let header {
            ForEach(["OBJECT", "TELESCOP", "INSTRUME", "FILTER", "DATE-OBS", "EXPTIME"], id: \.self) { key in
                if let value = header.string(key), !value.isEmpty { rawRow(key, value) }
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func rawRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
