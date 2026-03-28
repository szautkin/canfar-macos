// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct ResourceSelectorView: View {
    @Binding var cores: Int
    @Binding var ram: Int
    @Binding var gpus: Int
    let coreOptions: [Int]
    let ramOptions: [Int]
    let gpuOptions: [Int]

    private var minCores: Int { coreOptions.min() ?? 1 }
    private var maxCores: Int { coreOptions.max() ?? 16 }
    private var minRam: Int { ramOptions.min() ?? 1 }
    private var maxRam: Int { ramOptions.max() ?? 256 }
    private var maxGpus: Int { gpuOptions.max() ?? 0 }

    // Build power-of-2 values within RAM range
    private var ramPower2Values: [Int] {
        var values: [Int] = []
        var v = 1
        while v <= maxRam {
            if v >= minRam {
                values.append(v)
            }
            v *= 2
        }
        return values.isEmpty ? ramOptions : values
    }

    var body: some View {
        VStack(spacing: 12) {
            // CPU Cores
            HStack {
                Text("CPU Cores:")
                    .frame(width: 80, alignment: .leading)
                Stepper(value: $cores, in: minCores...maxCores) {
                    Text("\(cores)")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Slider(
                    value: Binding(
                        get: { Double(cores) },
                        set: { cores = Int($0) }
                    ),
                    in: Double(minCores)...Double(maxCores),
                    step: 1
                )
            }

            // RAM
            HStack {
                Text("RAM (GB):")
                    .frame(width: 80, alignment: .leading)
                Stepper(value: Binding(
                    get: { ramPower2Index },
                    set: { newIdx in
                        let clamped = max(0, min(newIdx, ramPower2Values.count - 1))
                        ram = ramPower2Values[clamped]
                    }
                ), in: 0...(ramPower2Values.count - 1)) {
                    Text("\(ram)")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Slider(
                    value: Binding(
                        get: { Double(ramPower2Index) },
                        set: { newVal in
                            let idx = Int(newVal.rounded())
                            let clamped = max(0, min(idx, ramPower2Values.count - 1))
                            ram = ramPower2Values[clamped]
                        }
                    ),
                    in: 0...Double(max(ramPower2Values.count - 1, 1)),
                    step: 1
                )
            }

            // GPUs
            if maxGpus > 0 {
                HStack {
                    Text("GPUs:")
                        .frame(width: 80, alignment: .leading)
                    Stepper(value: $gpus, in: 0...maxGpus) {
                        Text("\(gpus)")
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                    Spacer()
                }
            }
        }
    }

    private var ramPower2Index: Int {
        ramPower2Values.firstIndex(of: ram)
            ?? ramPower2Values.enumerated().min(by: { abs($0.element - ram) < abs($1.element - ram) })?.offset
            ?? 0
    }
}
