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
    let coreOptions: [Int]
    let ramOptions: [Int]
    let gpus: GPUChoice

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
                        .accessibilityLabel("Save resources as default")
                        .accessibilityValue(isDefault ? Text("On") : Text("Off"))
                    }
                }
            }

            if case .oneOrNone(let uses, let offered) = gpus {
                GPUCheckbox(isOn: uses, offered: offered)
            }

            if resourceType == "fixed" {
                ResourceSelectorView(
                    cores: $cores,
                    ram: $ram,
                    gpus: gpus.count,
                    coreOptions: coreOptions,
                    ramOptions: ramOptions,
                    gpuOptions: gpus.stepperOptions
                )
            }
        }
    }
}

/// How a form chooses GPUs (plan 41): an interactive session one or none,
/// with a checkbox; a batch job as many as the platform offers.
enum GPUChoice {
    case oneOrNone(Binding<Bool>, offered: Bool)
    case upTo(Binding<Int>, GPUOffer)

    /// The stepper's count: the batch job's; none for the checkbox's.
    var count: Binding<Int> {
        if case .upTo(let count, _) = self { return count }
        return .constant(0)
    }

    /// The stepper's counts; nil for the checkbox, which has no stepper.
    var stepperOptions: [Int]? {
        if case .upTo(_, let offer) = self { return offer.counts }
        return nil
    }
}

/// Use a GPU (plan 41): one GPU for an interactive session, or none —
/// disabled while the platform offers none. Ticking it makes the resources
/// Fixed (`SessionLaunchModel.usesAGPU`).
struct GPUCheckbox: View {
    @Binding var isOn: Bool
    let offered: Bool

    var body: some View {
        Toggle("Use a GPU", isOn: $isOn)
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .disabled(!offered)
            .help(offered ? Text("One GPU for this session; the resources become Fixed") : Text("This platform offers no GPUs"))
            .pointable("portal.launch.gpu")
    }
}
