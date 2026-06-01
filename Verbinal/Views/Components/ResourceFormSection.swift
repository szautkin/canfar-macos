// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The shared "Resources" block — a Flexible/Fixed segmented toggle plus the
/// fixed-resource pickers — used by the Standard, Advanced, and Headless
/// launch forms so all three present an identical resource UX. Previously
/// each form hand-rolled its own variant (the Headless tab even reimplemented
/// the Cores/RAM/GPU pickers instead of reusing `ResourceSelectorView`).
///
/// The "set as default" star is rendered only when `isDefault` /
/// `onToggleDefault` are supplied — i.e. for the interactive
/// `SessionLaunchModel` forms; the Headless form has no such concept and
/// omits it.
struct ResourceFormSection: View {
    @Binding var resourceType: String        // "flexible" | "fixed"
    @Binding var cores: Int
    @Binding var ram: Int
    @Binding var gpus: Int
    let coreOptions: [Int]
    let ramOptions: [Int]
    let gpuOptions: [Int]

    var isDefault: Bool? = nil
    var onToggleDefault: (() -> Void)? = nil

    var body: some View {
        Group {
            LabeledContent("Resources") {
                HStack(spacing: 4) {
                    Picker("", selection: $resourceType) {
                        Text("Flexible").tag("flexible")
                        Text("Fixed").tag("fixed")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if let isDefault, let onToggleDefault {
                        Button(action: onToggleDefault) {
                            Image(systemName: isDefault ? "star.fill" : "star")
                                .foregroundStyle(isDefault ? Color.yellow : Color.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(isDefault ? "Current default — tap to clear"
                                        : "Set current resources as default")
                    }
                }
            }

            if resourceType == "fixed" {
                ResourceSelectorView(
                    cores: $cores,
                    ram: $ram,
                    gpus: $gpus,
                    coreOptions: coreOptions,
                    ramOptions: ramOptions,
                    gpuOptions: gpuOptions
                )
            }
        }
    }
}
