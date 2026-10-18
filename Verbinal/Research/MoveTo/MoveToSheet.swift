// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

#if os(macOS)
/// Move To (plan 46): the active record's files between this Mac and the
/// person's storage — the two places side by side and the way between them,
/// each file now and after, copy (the default) or move, and a button that
/// says what it does. Keeping one copy of files in both places asks once more.
struct MoveToSheet: View {
    @Bindable var model: MoveToModel
    let close: () -> Void

    private var plan: MoveToPlan { model.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Move To").font(.title3.bold())
                Text(model.title).foregroundStyle(.secondary)
            }
            places
            files
            if !plan.isKeepOnly { copyOrMove }
            summary
            buttons
        }
        .padding(20)
        .frame(width: 600)
        .uiPresented(String(localized: "\(plan.buttonTitle)?"), .confirmation, isPresented: $model.confirmingRemoval)
        .alert(String(localized: "\(plan.buttonTitle)?"), isPresented: $model.confirmingRemoval) {
            Button(plan.buttonTitle, role: .destructive) { Task { await run() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(plan.summary.joined(separator: " "))
        }
    }

    // MARK: - Where

    private var places: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                placeCard(.mac, title: String(localized: "This Mac"), path: DownloadsFolder.displayPath(DownloadsFolder.url.path),
                          symbol: "laptopcomputer")
                Image(systemName: plan.to == .storage ? "arrow.right" : "arrow.left")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                placeCard(.storage, title: String(localized: "Your storage"), path: ResearchFileTransfer.folder + "/",
                          symbol: "cloud")
            }
            Picker(selection: $model.plan.to) {
                Text(plan.isKeepOnly ? "Keep on This Mac" : "To This Mac").tag(MoveToPlan.Place.mac)
                Text(plan.isKeepOnly ? "Keep in Your Storage" : "To Your Storage").tag(MoveToPlan.Place.storage)
            } label: {
                Text(plan.isKeepOnly ? "Keep" : "To")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.running)
            .pointable("research.moveTo.to")
        }
        .frame(maxWidth: .infinity)
    }

    /// One place: lit when the files go there — or, keeping one copy, stay.
    private func placeCard(_ place: MoveToPlan.Place, title: String, path: String, symbol: String) -> some View {
        let chosen = plan.to == place
        return HStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(chosen ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5))))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - What

    private var files: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files").font(.headline)
                Spacer()
                Text("Now").font(.caption).foregroundStyle(.secondary).frame(width: 44)
                // Room for the arrow and the size: nothing for the tools to read.
                Color.clear.frame(width: 14, height: 1)
                Text("After").font(.caption).foregroundStyle(.secondary).frame(width: 44)
                Color.clear.frame(width: 64, height: 1)
            }
            ForEach(plan.rows) { row in
                fileRow(row)
            }
        }
    }

    private func fileRow(_ row: MoveToPlan.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: Binding(get: { row.checked }, set: { on in
                if on { model.plan.unchecked.remove(row.name) } else { model.plan.unchecked.insert(row.name) }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    if let held = row.held {
                        Text(Self.words(held))
                            .font(.caption)
                            .foregroundStyle(held == .alreadyThere ? Color.secondary : Color.orange)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(row.step == nil || model.running)
            Spacer()
            FilePlacesBadge(places: row.now).frame(width: 44)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary).frame(width: 14)
                .accessibilityHidden(true)
            FilePlacesBadge(places: row.after).frame(width: 44)
            Group {
                switch model.moving[row.name] {
                case .moving?: ProgressView().controlSize(.small)
                case .moved?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case nil: Text(row.size.map(SharedFormatters.bytes) ?? "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, alignment: .trailing)
        }
    }

    /// Why a file does not go, in words.
    static func words(_ held: MoveToPlan.Held) -> String {
        switch held {
        case .alreadyThere: String(localized: "Already there")
        case .notOnMac: String(localized: "Not on this Mac any more")
        case .refused(let why): why
        }
    }

    // MARK: - How

    private var copyOrMove: some View {
        Picker(selection: $model.plan.keepCopy) {
            Text(plan.to == .storage ? "Copy — keep it on this Mac too" : "Copy — keep it in your storage too").tag(true)
            Text(plan.to == .storage ? "Move — remove it from this Mac once it is in your storage"
                                     : "Move — remove it from your storage once it is on this Mac").tag(false)
        } label: {
            Text("Copy or move")
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .disabled(model.running)
        .pointable("research.moveTo.keepCopy")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(plan.summary, id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(plan.warnings.contains(line) ? Color.orange : Color.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(model.running ? "Close" : "Cancel", action: close)
                .keyboardShortcut(.cancelAction)
                .pointable("research.moveTo.cancel")
            Button(plan.buttonTitle) {
                if plan.isKeepOnly { model.confirmingRemoval = true } else { Task { await run() } }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(plan.isKeepOnly ? .red : plan.removes ? .orange : .accentColor)
            .disabled(!plan.canRun || model.running)
            .pointable("research.moveTo.run")
        }
    }

    private func run() async {
        if await model.run() { close() }
    }
}
#endif
