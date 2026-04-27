// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

// Per-tab section views for ObservationDetailViewer. Each is a self-
// contained block of metadata cards. The sections render whatever data
// is available — row-only data renders immediately, CAOM2-only data
// renders when the async load completes.

// MARK: - Shared building blocks

/// A titled, material-backed card. The standard layout unit for grouping
/// related fields (Target / Telescope / Proposal / …).
struct DetailCard<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A right-aligned label / left-aligned value row. Renders nothing when
/// `value` is empty so cards naturally collapse around present fields.
struct DetailRow: View {
    let label: LocalizedStringKey
    let value: String
    var monospaced: Bool = false

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
                Text(value)
                    .font(monospaced ? .callout.monospacedDigit() : .callout)
                    .textSelection(.enabled)
                Spacer()
            }
        }
    }
}

/// Loading / auth-required / error state for sections that depend on the
/// async CAOM2 fetch.
struct AsyncStateBanner: View {
    let state: ObservationDetailModel.LoadState

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading observation detail…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        case .authRequired:
            Label(
                "This observation's full metadata requires CADC sign-in.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
        case .notFound:
            Label("Observation metadata not available.", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(8)
        case .loaded:
            EmptyView()
        }
    }
}

// MARK: - Overview tab

struct ObservationOverviewSection: View {
    let model: ObservationDetailModel

    var body: some View {
        VStack(spacing: 12) {
            targetCard
            instrumentCard
            proposalCard
            if model.loadState != .loaded {
                AsyncStateBanner(state: model.loadState)
            }
        }
    }

    private var targetCard: some View {
        let t = model.caom2?.target
        let rowName = model.targetName
        return DetailCard(title: "Target", symbol: "scope") {
            DetailRow(label: "Name", value: t?.name ?? rowName)
            DetailRow(label: "Type", value: t?.type ?? "")
            if let redshift = t?.redshift {
                DetailRow(label: "Redshift", value: String(format: "%.4f", redshift), monospaced: true)
            }
            if let moving = t?.moving {
                DetailRow(label: "Moving", value: moving ? String(localized: "Yes") : String(localized: "No"))
            }
            if let standard = t?.standard, standard {
                DetailRow(label: "Standard", value: String(localized: "Yes"))
            }
            if let kw = t?.keywords, !kw.isEmpty {
                DetailRow(label: "Keywords", value: kw.joined(separator: ", "))
            }
        }
    }

    private var instrumentCard: some View {
        let scope = model.caom2?.telescope
        let inst = model.caom2?.instrument
        let rowInstrument = model.columns.value(in: model.result, forID: "instrument")
        return DetailCard(title: "Instrument", symbol: "antenna.radiowaves.left.and.right") {
            DetailRow(label: "Telescope", value: scope?.name ?? "")
            DetailRow(label: "Instrument", value: inst?.name ?? rowInstrument)
            if let kw = inst?.keywords, !kw.isEmpty {
                DetailRow(label: "Keywords", value: kw.joined(separator: ", "))
            }
        }
    }

    private var proposalCard: some View {
        let p = model.caom2?.proposal
        let rowPI = model.columns.value(in: model.result, forID: "piname")
        let rowPropID = model.columns.value(in: model.result, forID: "proposalid")
        return DetailCard(title: "Proposal", symbol: "doc.text") {
            DetailRow(label: "ID", value: p?.id ?? rowPropID)
            DetailRow(label: "PI", value: p?.pi ?? rowPI)
            DetailRow(label: "Project", value: p?.project ?? "")
            DetailRow(label: "Title", value: p?.title ?? "")
            if let kw = p?.keywords, !kw.isEmpty {
                DetailRow(label: "Keywords", value: kw.joined(separator: ", "))
            }
        }
    }
}

// MARK: - Coverage tab

struct ObservationCoverageSection: View {
    let model: ObservationDetailModel

    var body: some View {
        VStack(spacing: 12) {
            if model.loadState == .loaded, let caom2 = model.caom2 {
                ForEach(Array(caom2.planes.enumerated()), id: \.offset) { _, plane in
                    planeCard(plane)
                }
                if caom2.planes.isEmpty {
                    Label("No plane coverage data.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                AsyncStateBanner(state: model.loadState)
            }
        }
    }

    @ViewBuilder
    private func planeCard(_ plane: CAOM2Observation.Plane) -> some View {
        DetailCard(title: planeTitle(plane), symbol: "rectangle.stack") {
            if let pos = plane.position {
                positionRows(pos)
            }
            if let energy = plane.energy {
                energyRows(energy)
            }
            if let time = plane.time {
                timeRows(time)
            }
            if let pol = plane.polarization, !pol.states.isEmpty {
                DetailRow(label: "Polarization", value: pol.states.joined(separator: ", "))
            }
        }
    }

    private func planeTitle(_ plane: CAOM2Observation.Plane) -> LocalizedStringKey {
        var parts: [String] = ["Plane: \(plane.productID)"]
        if let cl = plane.calibrationLevel {
            parts.append("L\(cl)")
        }
        if let dpt = plane.dataProductType { parts.append(dpt) }
        return LocalizedStringKey(parts.joined(separator: " · "))
    }

    @ViewBuilder
    private func positionRows(_ pos: CAOM2Observation.Position) -> some View {
        if let dim = pos.dimensionPixels {
            DetailRow(label: "Pixels", value: "\(dim.naxis1) × \(dim.naxis2)", monospaced: true)
        }
        if let r = pos.resolutionArcsec {
            DetailRow(label: "Resolution",
                      value: String(format: "%.3f\u{2033}", r),
                      monospaced: true)
        }
        if let s = pos.sampleSizeArcsec {
            DetailRow(label: "Pixel scale",
                      value: String(format: "%.3f\u{2033}/px", s),
                      monospaced: true)
        }
        if !pos.polygon.isEmpty {
            DetailRow(label: "Footprint", value: "\(pos.polygon.count)-vertex polygon")
        }
    }

    @ViewBuilder
    private func energyRows(_ e: CAOM2Observation.Energy) -> some View {
        if let lower = e.lowerMetres {
            DetailRow(label: "Min wavelength",
                      value: SpectralFormatter(unit: pickEnergyUnit(lower)).format(String(lower)),
                      monospaced: true)
        }
        if let upper = e.upperMetres {
            DetailRow(label: "Max wavelength",
                      value: SpectralFormatter(unit: pickEnergyUnit(upper)).format(String(upper)),
                      monospaced: true)
        }
        if let band = e.bandpassName, !band.isEmpty {
            DetailRow(label: "Filter", value: band)
        }
        if let emBand = e.emBand, !emBand.isEmpty {
            DetailRow(label: "EM band", value: emBand)
        }
        if let r = e.resolvingPower {
            DetailRow(label: "R", value: String(format: "%.0f", r), monospaced: true)
        }
    }

    /// Pick the most readable unit for a metre wavelength: nm for visible/UV,
    /// μm for IR, m for radio. Falls back to metres for extremes.
    private func pickEnergyUnit(_ metres: Double) -> SpectralUnit {
        switch metres {
        case 1e-10..<1e-9:  return .angstroms
        case 1e-9..<1e-6:   return .nanometres
        case 1e-6..<1e-3:   return .micrometres
        case 1e-3..<1:      return .millimetres
        default:            return .metres
        }
    }

    @ViewBuilder
    private func timeRows(_ t: CAOM2Observation.Time) -> some View {
        if let lower = t.lowerMJD {
            DetailRow(label: "Start", value: MJDFormatter(style: .dateAndTime).format(String(lower)), monospaced: true)
        }
        if let upper = t.upperMJD {
            DetailRow(label: "End", value: MJDFormatter(style: .dateAndTime).format(String(upper)), monospaced: true)
        }
        if let exp = t.exposureSeconds {
            DetailRow(label: "Exposure",
                      value: FixedDurationFormatter(unit: .seconds).format(String(exp)),
                      monospaced: true)
        }
    }
}

// MARK: - Files tab

struct ObservationFilesSection: View {
    let model: ObservationDetailModel

    var body: some View {
        VStack(spacing: 12) {
            if model.loadState == .loaded, let caom2 = model.caom2 {
                ForEach(Array(caom2.planes.enumerated()), id: \.offset) { _, plane in
                    planeFiles(plane)
                }
                if caom2.planes.flatMap(\.artifacts).isEmpty {
                    Label("No artifacts published for this observation.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                AsyncStateBanner(state: model.loadState)
            }
        }
    }

    @ViewBuilder
    private func planeFiles(_ plane: CAOM2Observation.Plane) -> some View {
        if !plane.artifacts.isEmpty {
            DetailCard(title: LocalizedStringKey("Plane: \(plane.productID)"), symbol: "doc.zipper") {
                ForEach(Array(plane.artifacts.enumerated()), id: \.offset) { _, artifact in
                    artifactRow(artifact)
                }
            }
        }
    }

    @Environment(\.openURL) private var openURL

    @ViewBuilder
    private func artifactRow(_ artifact: CAOM2Observation.Artifact) -> some View {
        let filename = artifact.uri.split(separator: "/").last.map(String.init) ?? artifact.uri
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(artifact.uri))
                Spacer()
                if let url = TAPClient.downloadURL(publisherID: artifact.uri) {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Download"))
                }
            }
            HStack(spacing: 12) {
                if let pt = artifact.productType, !pt.isEmpty {
                    Text(pt)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.tertiary, in: Capsule())
                }
                if let length = artifact.contentLength {
                    Text(formatBytes(length))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let type = artifact.contentType {
                    Text(type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        SharedFormatters.bytes(bytes)
    }
}

// MARK: - Provenance tab

struct ObservationProvenanceSection: View {
    let model: ObservationDetailModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 12) {
            if model.loadState == .loaded, let caom2 = model.caom2 {
                ForEach(Array(caom2.planes.enumerated()), id: \.offset) { _, plane in
                    planeProvenance(plane)
                }
                if caom2.planes.allSatisfy({ $0.provenance == nil && $0.metrics == nil && $0.quality == nil }) {
                    Label("No provenance data.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                AsyncStateBanner(state: model.loadState)
            }
        }
    }

    @ViewBuilder
    private func planeProvenance(_ plane: CAOM2Observation.Plane) -> some View {
        if plane.provenance != nil || plane.metrics != nil || plane.quality != nil {
            DetailCard(title: LocalizedStringKey("Plane: \(plane.productID)"), symbol: "scroll") {
                if let p = plane.provenance {
                    DetailRow(label: "Pipeline", value: p.name ?? "")
                    DetailRow(label: "Version", value: p.version ?? "")
                    DetailRow(label: "Project", value: p.project ?? "")
                    DetailRow(label: "Producer", value: p.producer ?? "")
                    DetailRow(label: "Run ID", value: p.runID ?? "")
                    if let ref = p.reference, let url = URL(string: ref) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Reference")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .trailing)
                            Button(ref) { openURL(url) }
                                .buttonStyle(.link)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                    } else {
                        DetailRow(label: "Reference", value: p.reference ?? "")
                    }
                    if !p.inputs.isEmpty {
                        DetailRow(label: "Inputs", value: "\(p.inputs.count)")
                    }
                }
                if let q = plane.quality, !q.isEmpty {
                    DetailRow(label: "Quality", value: q)
                }
                if let m = plane.metrics {
                    if let v = m.magLimit { DetailRow(label: "Mag limit", value: String(format: "%.2f", v), monospaced: true) }
                    if let v = m.background { DetailRow(label: "Background", value: String(format: "%.4g", v), monospaced: true) }
                    if let v = m.sourceNumberDensity { DetailRow(label: "Sources", value: String(format: "%.0f", v), monospaced: true) }
                }
            }
        }
    }
}

// MARK: - Raw tab

struct ObservationRawSection: View {
    let model: ObservationDetailModel

    var body: some View {
        DetailCard(title: "All Columns", symbol: "tablecells") {
            ForEach(model.columns.list) { col in
                let raw = model.columns.value(in: model.result, forID: col.id)
                if !raw.isEmpty && col.id != "download" && col.id != "preview" {
                    DetailRow(
                        label: LocalizedStringKey(col.label),
                        value: CellFormatterRegistry.format(id: col.id, raw: raw),
                        monospaced: true
                    )
                }
            }
        }
    }
}
