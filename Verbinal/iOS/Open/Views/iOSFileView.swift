// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import VerbinalKit

/// An opened file, header first (plan 47 3.2): what it is, its HDUs, the
/// cards that say what is in it, the whole header to search — all before any
/// pixels move. From storage, the file itself comes down when the person asks.
struct iOSFileView: View {
    @Bindable var inspection: FileInspection
    @State private var selectedHDU = 0

    /// The cards that say what a file holds and whether it is whole, when present.
    static let keyCards = ["OBJECT", "TELESCOP", "INSTRUME", "DATE-OBS", "EXPTIME", "FILTER", "BUNIT",
                           "NAXIS1", "NAXIS2", "NAXIS3", "BITPIX", "CTYPE1", "CTYPE2", "CTYPE3",
                           "CRVAL1", "CRVAL2", "CRVAL3", "RESTFRQ", "CHECKSUM", "DATASUM"]

    private var hdus: [FITSHDUnit] { inspection.structure.value ?? [] }
    private var hdu: FITSHDUnit? { hdus.indices.contains(selectedHDU) ? hdus[selectedHDU] : hdus.first }

    var body: some View {
        List {
            summarySection
            if let problem = inspection.structure.problem {
                Section {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Button("Try Again") { Task { await inspection.inspect() } }
                }
            }
            if hdus.count > 1 { hdusSection }
            if let hdu { cardsSection(hdu) }
            fileSection
        }
        .navigationTitle(inspection.file.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if inspection.structure.isLoadingFirst { ProgressView("Reading the headers…") } }
        .task { if inspection.structure.value == nil { await inspection.inspect() } }
        .refreshable { await inspection.inspect() }
    }

    // MARK: - What it is

    private var summarySection: some View {
        Section {
            LabeledContent("Where", value: whereText)
            if let size = inspection.file.size {
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if !hdus.isEmpty {
                LabeledContent("HDUs", value: "\(hdus.count)")
            }
            if inspection.isCube {
                Label("A spectral cube: it opens in Cube.", systemImage: "cube")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var whereText: String {
        switch inspection.file.place {
        case .storage(let path): return String(localized: "Your storage: \(path)")
        case .device: return String(localized: "This device")
        }
    }

    // MARK: - HDUs

    private var hdusSection: some View {
        Section("HDUs") {
            ForEach(hdus) { unit in
                Button {
                    selectedHDU = unit.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: Self.title(of: unit)).fontWeight(unit.id == selectedHDU ? .semibold : .regular)
                            Text(verbatim: Self.shape(of: unit)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if unit.id == selectedHDU {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "#0 PRIMARY", "#1 SCI".
    static func title(of unit: FITSHDUnit) -> String {
        let name = unit.header.string("EXTNAME") ?? (unit.id == 0 ? "PRIMARY" : unit.header.string("XTENSION") ?? "")
        return "#\(unit.id) \(name)"
    }

    /// "IMAGE · 4096 × 4096 · BITPIX −32", "BINTABLE · 120 rows".
    static func shape(of unit: FITSHDUnit) -> String {
        let header = unit.header
        let kind = header.string("XTENSION") ?? "IMAGE"
        let axes = (0..<header.naxis).map { header.int("NAXIS\($0 + 1)") }
        var parts = [kind]
        if kind.uppercased().contains("TABLE") {
            parts.append(String(localized: "\(header.naxis2) rows"))
        } else if !axes.isEmpty {
            parts.append(axes.map(String.init).joined(separator: " × "))
            parts.append("BITPIX \(header.bitpix)")
        } else {
            parts.append(String(localized: "no data"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Its header

    private func cardsSection(_ unit: FITSHDUnit) -> some View {
        Section {
            ForEach(Self.keyCards.filter { unit.header.contains($0) }, id: \.self) { key in
                LabeledContent(key, value: unit.header.string(key) ?? "")
                    .font(.system(.footnote, design: .monospaced))
            }
            NavigationLink {
                iOSHeaderView(title: Self.title(of: unit), cards: unit.header.orderedCards)
            } label: {
                Label("Whole Header (\(unit.header.orderedCards.count) cards)", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text(verbatim: Self.title(of: unit))
        } footer: {
            if unit.header.contains("CHECKSUM") || unit.header.contains("DATASUM") {
                Text("It carries a CHECKSUM and DATASUM, to check that the file is whole.")
            }
        }
    }

    // MARK: - The file itself

    @ViewBuilder
    private var fileSection: some View {
        Section {
            switch inspection.local {
            case .ready(let url):
                Label(inspection.file.isRemote ? "Downloaded to this device" : "On this device", systemImage: "checkmark.circle")
                ShareLink(item: url) { Label("Share the File", systemImage: "square.and.arrow.up") }
            case .working:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: inspection.progress)
                    HStack {
                        Text(inspection.progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", role: .cancel) { inspection.cancelDownload() }
                    }
                }
            case .failed(let problem, _):
                Label(problem.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                downloadButton
            case .idle:
                downloadButton
            }
        } footer: {
            if inspection.file.isRemote, case .idle = inspection.local {
                Text("Downloads go to this device's cache, which iOS may empty when it needs space.")
            }
        }
    }

    private var downloadButton: some View {
        Button {
            inspection.download()
        } label: {
            Label(downloadTitle, systemImage: "arrow.down.circle")
        }
    }

    private var downloadTitle: String {
        guard let size = inspection.file.size else { return String(localized: "Download") }
        return String(localized: "Download (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
    }
}

/// A header's every card, searchable.
struct iOSHeaderView: View {
    let title: String
    let cards: [FITSCard]
    @State private var query = ""

    private var shown: [(offset: Int, element: FITSCard)] {
        let all = Array(cards.enumerated())
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.element.keyword.localizedCaseInsensitiveContains(query) || $0.element.value.localizedCaseInsensitiveContains(query)
                || $0.element.comment.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List(shown, id: \.offset) { item in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.element.keyword).fontWeight(.semibold)
                    Spacer()
                    Text(item.element.text).multilineTextAlignment(.trailing)
                }
                if !item.element.comment.isEmpty {
                    Text(item.element.comment).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
        }
        .searchable(text: $query, prompt: Text("Keyword, value or comment"))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
