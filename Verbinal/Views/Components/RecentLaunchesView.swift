// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

struct RecentLaunchesView: View {
    @Bindable var store: RecentLaunchStore
    var launchModel: SessionLaunchModel?
    var onRelaunched: (() -> Void)?
    @State private var filterText = ""
    @State private var showRelaunchProgress = false

    private var filteredLaunches: [RecentLaunch] {
        guard !filterText.isEmpty else { return store.launches }
        let query = filterText.lowercased()
        return store.launches.filter {
            $0.name.lowercased().contains(query) ||
            $0.type.lowercased().contains(query) ||
            $0.imageLabel.lowercased().contains(query)
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Recent Launches", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    if !store.launches.isEmpty {
                        Button("Clear") {
                            store.clear()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }

                if !store.launches.isEmpty {
                    TextField("Filter...", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }

                if filteredLaunches.isEmpty {
                    HStack {
                        Spacer()
                        Text(store.launches.isEmpty ? "No recent launches" : "No matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(filteredLaunches) { launch in
                                recentLaunchCard(launch)
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                }
            }
        }
        .sheet(isPresented: $showRelaunchProgress) {
            if let model = launchModel {
                LaunchProgressSheet(model: model) {
                    showRelaunchProgress = false
                    onRelaunched?()
                }
            }
        }
    }

    @ViewBuilder
    private func recentLaunchCard(_ launch: RecentLaunch) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Type icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(typeColor(launch.type).opacity(0.15))
                if let asset = typeImageAsset(launch.type) {
                    Image(asset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: typeIcon(launch.type))
                        .font(.caption)
                        .foregroundStyle(typeColor(launch.type))
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(launch.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(launch.type)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(typeColor(launch.type).opacity(0.15))
                        .foregroundStyle(typeColor(launch.type))
                        .clipShape(Capsule())
                }

                Text(launch.imageLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    if launch.resourceType == "fixed" {
                        Text("CPU: \(launch.cores) | RAM: \(launch.ram)G")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Flexible")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text(formatDate(launch.launchedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Button("Relaunch") {
                        showRelaunchProgress = true
                        Task {
                            if let model = launchModel {
                                let success = await model.relaunch(launch)
                                if success { onRelaunched?() }
                            }
                        }
                    }
                    .disabled(launchModel?.isAtSessionLimit ?? true)

                    Spacer()

                    Button("Remove", role: .destructive) {
                        store.remove(launch)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private func typeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "notebook": return .blue
        case "desktop": return .purple
        case "carta": return .teal
        case "contributed": return Color(.systemOrange)
        case "firefly": return .orange
        default: return .gray
        }
    }

    private func typeImageAsset(_ type: String) -> String? {
        switch type.lowercased() {
        case "notebook": return "session-notebook"
        case "desktop": return "session-desktop"
        case "carta": return "session-carta"
        case "contributed": return "session-contributed"
        case "firefly": return "session-firefly"
        default: return nil
        }
    }

    private func typeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "notebook": return "book.pages"
        case "desktop": return "desktopcomputer"
        case "carta": return "map"
        case "contributed": return "shippingbox"
        case "firefly": return "flame"
        default: return "terminal"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
