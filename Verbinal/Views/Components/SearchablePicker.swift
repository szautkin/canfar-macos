// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The rules of a searchable choice, apart from any view: when a list is
/// short enough for a menu, how tall its panel is, and what a search finds.
enum SearchableChoice {
    /// Up to this many choices, a pop-up menu: nothing to search for.
    static let menuUpTo = 12
    /// The panel shows at most this many rows, and scrolls the rest.
    static let visibleRows = 12
    static let rowHeight: CGFloat = 24
    static let panelWidth: CGFloat = 340

    static func usesMenu(count: Int) -> Bool { count <= menuUpTo }

    /// The choices whose words hold every word searched for, in any case and
    /// with or without accents, in their order; all of them for no words.
    static func matches<Value>(_ options: [Value], query: String, label: (Value) -> String) -> [Value] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return options }
        return options.filter { option in
            let text = label(option)
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The choice `step` rows from `current` among `matches`, held to its ends.
    static func moved<Value: Equatable>(_ current: Value?, by step: Int, in matches: [Value]) -> Value? {
        guard !matches.isEmpty else { return nil }
        guard let current, let index = matches.firstIndex(of: current) else { return step > 0 ? matches.first : matches.last }
        return matches[min(max(index + step, 0), matches.count - 1)]
    }
}

/// A choice from a list that can run long — the launch form's projects and
/// images. A short list is a pop-up menu, as ever. A long one opens a panel
/// with a search field and a list at most `visibleRows` rows tall, scrolled
/// to the choice: ↑ ↓ move, Return chooses, Esc closes.
///
/// It reads as a pop-up to the pointing tools (`list_ui_targets`, `open_ui`)
/// and its rows as items `select_ui` chooses.
struct SearchablePicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    /// What it says while the selection is none of the options.
    var placeholder: LocalizedStringKey = "Choose…"

    @State private var isOpen = false

    var body: some View {
        if SearchableChoice.usesMenu(count: options.count) {
            Picker(title, selection: $selection) {
                if !options.contains(selection) {
                    Text(placeholder).tag(selection)
                }
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .labelsHidden()
        } else {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    current.lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .help(Text(title))
            .accessibilityLabel(Text(title))
            .accessibilityValue(current)
            .accessibilityIdentifier(isOpen ? PointableID.popUpOpen : PointableID.popUp)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                SearchablePickerPanel(title: title, selection: $selection, options: options, label: label) {
                    isOpen = false
                }
            }
        }
    }

    private var current: Text {
        options.contains(selection) ? Text(verbatim: label(selection)) : Text(placeholder)
    }
}

/// The panel of a long `SearchablePicker`: its search field, how many match,
/// and the matching rows.
private struct SearchablePickerPanel<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    let close: () -> Void

    @State private var query = ""
    @State private var highlighted: Value?
    @FocusState private var searching: Bool

    private var matches: [Value] { SearchableChoice.matches(options, query: query, label: label) }

    var body: some View {
        let matches = matches
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .accessibilityLabel(Text("Search"))
                .onKeyPress(.downArrow) { highlighted = SearchableChoice.moved(highlighted, by: 1, in: matches); return .handled }
                .onKeyPress(.upArrow) { highlighted = SearchableChoice.moved(highlighted, by: -1, in: matches); return .handled }
                .onSubmit {
                    if let chosen = highlighted.flatMap({ matches.contains($0) ? $0 : nil }) ?? matches.first { choose(chosen) }
                }
                .onChange(of: query) { _, _ in
                    if let highlighted, matches.contains(highlighted) { return }
                    highlighted = matches.first
                }
            Text("\(matches.count) of \(options.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if matches.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: SearchableChoice.rowHeight * 2)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches, id: \.self) { option in
                                row(option).id(option)
                            }
                        }
                    }
                    .frame(height: CGFloat(min(matches.count, SearchableChoice.visibleRows)) * SearchableChoice.rowHeight)
                    .onAppear { proxy.scrollTo(selection, anchor: .center) }
                    .onChange(of: highlighted) { _, now in
                        if let now { proxy.scrollTo(now) }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: SearchableChoice.panelWidth)
        .onAppear {
            highlighted = selection
            searching = true
        }
    }

    private func row(_ option: Value) -> some View {
        let name = label(option)
        return HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .imageScale(.small)
                .opacity(option == selection ? 1 : 0)
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: SearchableChoice.rowHeight)
        .background(option == highlighted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { choose(option) }
        .onHover { inside in if inside { highlighted = option } }
        .pointableItem(name, whole: true) { choose(option) }
        .accessibilityAddTraits(option == selection ? .isSelected : [])
    }

    private func choose(_ option: Value) {
        selection = option
        close()
    }
}
