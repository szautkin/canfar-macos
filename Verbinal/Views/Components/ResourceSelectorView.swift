// Verbinal - A CANFAR Science Portal Companion
// Copyright (C) 2025-2026 Serhii Zautkin
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
