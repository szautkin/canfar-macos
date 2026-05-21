// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// LEFT pane of the discovery sheet — sectioned, scrollable list of
/// every distinct package known across all *successful* manifests,
/// with checkboxes the user toggles to refine the right pane.
///
/// Sections appear in the order most users care about:
/// OS family / OS version / Python / R / Conda / system-pkg manager
/// families (dpkg / rpm / apk).
///
/// Width is fixed at 280pt by the parent sheet — a `List` here gives
/// us the system's native sectioned look + accessibility for free.
struct PackageFilterPane: View {
    @Bindable var model: ImageDiscoveryModel

    /// Local alias so the existing `filtered(_:)` helper and OS-
    /// version filter keep the same call shape after the global
    /// search field was split into per-pane fields.
    private var searchText: String { model.packageSearchText }

    var body: some View {
        VStack(spacing: 0) {
            // Pane-scoped search — narrows ONLY the checkbox lists
            // here, not the image rows in the right pane.
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter packages, OS, …", text: $model.packageSearchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List {
                osFamilySection
                osVersionSection
                packageSection(title: "Python", names: model.allPackages.python,
                               category: .python,
                               binding: pythonBinding,
                               selected: model.query.python)
                packageSection(title: "R", names: model.allPackages.r,
                               category: .r,
                               binding: rBinding,
                               selected: model.query.r)
                packageSection(title: "System (apt / dpkg)",
                               names: model.allPackages.dpkg,
                               category: .dpkg,
                               binding: dpkgBinding,
                               selected: model.query.dpkg)
                packageSection(title: "System (rpm)",
                               names: model.allPackages.rpm,
                               category: .rpm,
                               binding: rpmBinding,
                               selected: model.query.rpm)
                packageSection(title: "System (apk)",
                               names: model.allPackages.apk,
                               category: .apk,
                               binding: apkBinding,
                               selected: model.query.apk)

                if !model.query.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            model.query = PackageQuery()
                        } label: {
                            Label("Clear all filters", systemImage: "xmark.circle")
                        }
                        .keyboardShortcut(.delete, modifiers: .command)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var osFamilySection: some View {
        if !model.allPackages.osFamilies.isEmpty {
            let available = model.availableValues(for: .osFamily)
            Section("OS family") {
                ForEach(filtered(Array(model.allPackages.osFamilies)), id: \.self) { family in
                    checkbox(label: family,
                             isOn: bindingForSet(\.osFamilies, value: family),
                             enabled: isEnabled(family,
                                                available: available,
                                                selected: model.query.osFamilies))
                }
            }
        }
    }

    /// One row per (family, version) combination known to the
    /// catalogue. Used to populate the OS-version checkbox list
    /// while keeping family + version separable — the previous
    /// approach concatenated them into a single string and tried
    /// to split at the first space, which silently mangled
    /// multi-word families like `debian gnu/linux` (the recovered
    /// "version" became `gnu/linux 13 (trixie)` and never matched
    /// the manifest's actual `osVersion = "13 (trixie)"`).
    private struct OSVersionEntry: Hashable {
        let family: String
        let version: String
        var label: String { "\(family) \(version)" }
    }

    private var osVersionEntries: [OSVersionEntry] {
        // Only show versions for the families the user has selected
        // (or all known families when no family filter is active).
        let scopedFamilies = model.query.osFamilies.isEmpty
            ? Array(model.allPackages.osVersionsByFamily.keys)
            : Array(model.query.osFamilies)
        return scopedFamilies.flatMap { fam in
            (model.allPackages.osVersionsByFamily[fam] ?? [])
                .map { OSVersionEntry(family: fam, version: $0) }
        }
    }

    @ViewBuilder
    private var osVersionSection: some View {
        let entries = osVersionEntries.filter { searchText.isEmpty
            || $0.label.localizedCaseInsensitiveContains(searchText) }
        if !entries.isEmpty {
            let available = model.availableValues(for: .osVersion)
            Section("OS version") {
                ForEach(entries, id: \.self) { entry in
                    checkbox(label: entry.label,
                             isOn: bindingForSet(\.osVersions, value: entry.version),
                             enabled: isEnabled(entry.version,
                                                available: available,
                                                selected: model.query.osVersions))
                }
            }
        }
    }

    @ViewBuilder
    private func packageSection(
        title: String,
        names: Set<String>,
        category: PackageQuery.Category,
        binding: @escaping (String) -> Binding<Bool>,
        selected: Set<String>
    ) -> some View {
        if !names.isEmpty {
            let sorted = filtered(Array(names))
            let available = model.availableValues(for: category)
            Section("\(title) (\(sorted.count))") {
                ForEach(sorted, id: \.self) { name in
                    checkbox(label: name,
                             isOn: binding(name),
                             enabled: isEnabled(name, available: available, selected: selected))
                }
            }
        }
    }

    @ViewBuilder
    private func checkbox(label: String, isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(enabled ? .primary : .tertiary)
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled)
        .help(enabled ? "" : "No image with the current filters has this value")
    }

    /// Checkbox stays enabled when:
    ///   - the value would yield ≥1 result given other filters, OR
    ///   - the user already has it ticked (so they can untick it
    ///     without scrolling to find a different way out).
    private func isEnabled(_ value: String, available: Set<String>, selected: Set<String>) -> Bool {
        available.contains(value) || selected.contains(value)
    }

    // MARK: - Search-text filtering

    private func filtered(_ names: [String]) -> [String] {
        let unique = Array(Set(names)).sorted()
        guard !searchText.isEmpty else { return unique }
        let needle = searchText.lowercased()
        return unique.filter { $0.lowercased().contains(needle) }
    }

    // MARK: - Bindings into PackageQuery

    private func bindingForSet(
        _ keyPath: WritableKeyPath<PackageQuery, Set<String>>,
        value: String
    ) -> Binding<Bool> {
        Binding(
            get: { model.query[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn { model.query[keyPath: keyPath].insert(value) }
                else    { model.query[keyPath: keyPath].remove(value) }
            }
        )
    }

    private var pythonBinding: (String) -> Binding<Bool> {
        { name in self.bindingForSet(\.python, value: name) }
    }
    private var rBinding: (String) -> Binding<Bool> {
        { name in self.bindingForSet(\.r, value: name) }
    }
    private var dpkgBinding: (String) -> Binding<Bool> {
        { name in self.bindingForSet(\.dpkg, value: name) }
    }
    private var rpmBinding: (String) -> Binding<Bool> {
        { name in self.bindingForSet(\.rpm, value: name) }
    }
    private var apkBinding: (String) -> Binding<Bool> {
        { name in self.bindingForSet(\.apk, value: name) }
    }
}
