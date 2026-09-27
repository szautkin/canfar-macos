// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The marks on the image on screen: the pencil and its shape, the style
/// of the picked-out mark (or the next one), the list — each row picks
/// its mark out and goes to it, and has the mark's menu — export and clear.
struct MarksPanel: View {
    @Bindable var editor: MarkEditor
    /// Nil when nothing is open.
    let target: MarkStore.Target?
    let host: MarkCommandHost?

    @State private var filter = ""
    @State private var confirmingClear = false
    /// A colour being dragged in the picker; applied once it settles, so a
    /// drag across the wheel is one write, not sixty.
    @State private var pendingColour: Color?

    var body: some View {
        let marks = target.map(editor.marks(on:)) ?? []
        let shown = MarkSummary.filtered(marks, by: filter)
        let selectedID = target.flatMap(editor.selectedID(on:))

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Marks").font(.caption.bold())
                Spacer()
                if !marks.isEmpty {
                    Text("\(marks.count)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Toggle(isOn: $editor.drawArmed) {
                    Label("Draw", systemImage: "pencil.tip")
                }
                .toggleStyle(.button)
                .help("While on, click or drag on the image to add a mark")
                .disabled(target == nil)
                Picker("Shape", selection: $editor.kind) {
                    Text("Circle").tag(Mark.Kind.circle)
                    Text("Box").tag(Mark.Kind.rect)
                    Text("Callout").tag(Mark.Kind.callout)
                    Text("Text").tag(Mark.Kind.text)
                }
                .labelsHidden()
                .fixedSize()
            }
            .controlSize(.small)

            styleRow

            if marks.count > 3 {
                TextField("Filter marks…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            if marks.isEmpty {
                Text("Nothing marked yet. Turn on Draw, then click the image.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(shown) { mark in
                    row(mark, selected: mark.id == selectedID)
                }
                if shown.isEmpty {
                    Text("No mark matches.").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if selectedID != nil {
                Text("Drag a grip to resize, the shape to move it; double-click to rename.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Menu("Export") {
                    Button("DS9 Regions…") { host?.export(.ds9) }
                    Button("JSON…") { host?.export(.json) }
                }
                .fixedSize()
                .disabled(marks.isEmpty || host == nil)
                Spacer()
                Button("Clear All", role: .destructive) { confirmingClear = true }
                    .disabled(marks.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
        .confirmationDialog("Remove all \(marks.count) marks from this image?",
                            isPresented: $confirmingClear) {
            Button("Remove All", role: .destructive) { if let target { editor.clear(target) } }
        }
        .task(id: pendingColour) {
            guard let colour = pendingColour else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            if let hex = colour.hexString {
                var style = editor.style(on: target)
                style.colour = hex
                editor.applyStyle(style, on: target)
            }
            pendingColour = nil
        }
    }

    // MARK: - Pieces

    private var styleRow: some View {
        let style = editor.style(on: target)
        return HStack(spacing: 8) {
            ColorPicker("Colour", selection: Binding(
                get: { pendingColour ?? Color(hex: style.colour) },
                set: { pendingColour = $0 }), supportsOpacity: false)
                .labelsHidden()
                .help("Mark colour")
            Toggle(isOn: Binding(get: { style.bold }, set: { v in restyle { $0.bold = v } })) {
                Text("B").bold()
            }
            .toggleStyle(.button)
            .help("Bold label")
            .accessibilityLabel(Text("Bold label"))
            Stepper(value: Binding(get: { style.fontSize }, set: { v in restyle { $0.fontSize = v } }),
                    in: 6...72, step: 1) {
                Text("\(Int(style.fontSize)) pt").font(.caption2.monospacedDigit())
            }
            .help("Label size")
            Stepper(value: Binding(get: { style.stroke }, set: { v in restyle { $0.stroke = v } }),
                    in: 0.5...20, step: 0.5) {
                Text("\(style.stroke, specifier: "%g") px").font(.caption2.monospacedDigit())
            }
            .help("Outline thickness")
        }
        .controlSize(.small)
    }

    /// Changes one field of the current style and applies it.
    private func restyle(_ change: (inout Mark.Style) -> Void) {
        var style = editor.style(on: target)
        change(&style)
        editor.applyStyle(style, on: target)
    }

    private func row(_ mark: Mark, selected: Bool) -> some View {
        let title = MarkSummary.title(mark)
        let detail = MarkSummary.detail(mark)
        return Button {
            guard let target else { return }
            editor.select(mark.id, on: target)
            host?.perform(.centre, on: mark)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: mark.effectiveStyle.colour)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption).lineLimit(1)
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2).padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let host { MarkMenuButtons(mark: mark, host: host) }
        }
        .accessibilityLabel(Text("\(title), \(detail)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
