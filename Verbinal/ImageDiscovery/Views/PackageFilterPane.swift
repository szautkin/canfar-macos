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
    var searchText: String

    var body: some View {
        List {
            osFamilySection
            osVersionSection
            packageSection(title: "Python", names: model.allPackages.python,
                           binding: pythonBinding)
            packageSection(title: "R", names: model.allPackages.r,
                           binding: rBinding)
            packageSection(title: "System (apt / dpkg)",
                           names: model.allPackages.dpkg,
                           binding: dpkgBinding)
            packageSection(title: "System (rpm)",
                           names: model.allPackages.rpm,
                           binding: rpmBinding)
            packageSection(title: "System (apk)",
                           names: model.allPackages.apk,
                           binding: apkBinding)

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

    // MARK: - Sections

    @ViewBuilder
    private var osFamilySection: some View {
        if !model.allPackages.osFamilies.isEmpty {
            Section("OS family") {
                ForEach(filtered(Array(model.allPackages.osFamilies)), id: \.self) { family in
                    checkbox(label: family,
                             isOn: bindingForSet(\.osFamilies, value: family))
                }
            }
        }
    }

    private var osVersionLabels: [String] {
        // Only show versions for the families the user has selected
        // (or all known families when no family filter is active).
        let scopedFamilies = model.query.osFamilies.isEmpty
            ? Array(model.allPackages.osVersionsByFamily.keys)
            : Array(model.query.osFamilies)
        return scopedFamilies.flatMap { fam in
            (model.allPackages.osVersionsByFamily[fam] ?? []).map { "\(fam) \($0)" }
        }
    }

    @ViewBuilder
    private var osVersionSection: some View {
        if !osVersionLabels.isEmpty {
            Section("OS version") {
                ForEach(filtered(osVersionLabels), id: \.self) { combined in
                    let parts = combined.split(separator: " ", maxSplits: 1).map(String.init)
                    let version = parts.count == 2 ? parts[1] : combined
                    checkbox(label: combined,
                             isOn: bindingForSet(\.osVersions, value: version))
                }
            }
        }
    }

    @ViewBuilder
    private func packageSection(
        title: String,
        names: Set<String>,
        binding: @escaping (String) -> Binding<Bool>
    ) -> some View {
        if !names.isEmpty {
            let sorted = filtered(Array(names))
            Section("\(title) (\(sorted.count))") {
                ForEach(sorted, id: \.self) { name in
                    checkbox(label: name, isOn: binding(name))
                }
            }
        }
    }

    @ViewBuilder
    private func checkbox(label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
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
