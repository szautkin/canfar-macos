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

struct SessionCardView: View {
    let session: Session
    var onOpen: () -> Void
    var onDelete: () -> Void
    var onRenew: () -> Void
    var onEvents: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Icon + status
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(typeColor.opacity(0.15))
                    if let assetName = typeImageAsset {
                        Image(assetName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: typeIcon)
                            .font(.title3)
                            .foregroundStyle(typeColor)
                    }
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(ImageParser.parse(RawImage(id: session.containerImage, types: [])).label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Status badge
                Text(session.status)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())
            }

            Divider()

            // Info rows
            VStack(alignment: .leading, spacing: 4) {
                Label(formatTime(session.startedTime), systemImage: "clock")
                Label(formatTime(session.expiresTime), systemImage: "timer")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Resources
            HStack(spacing: 8) {
                if !session.cpuAllocated.isEmpty {
                    Label("CPU: \(session.cpuAllocated)", systemImage: "cpu")
                }
                if !session.memoryAllocated.isEmpty {
                    Label("RAM: \(session.memoryAllocated)", systemImage: "memorychip")
                }
                if !session.gpuAllocated.isEmpty && session.gpuAllocated != "0" {
                    Label("GPU: \(session.gpuAllocated)", systemImage: "rectangle.stack")
                }
                Spacer()
                if !session.isFixedResources {
                    Text("FLEX")
                        .font(.system(.caption2, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Divider()

            // Actions
            HStack(spacing: 6) {
                Button("Open") { onOpen() }
                    .disabled(!session.isRunning)
                Button("Renew") { onRenew() }
                    .disabled(!session.isRunning)
                Button("Events") { onEvents() }
                Spacer()
                Button("Delete", role: .destructive) { onDelete() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Colors

    private var statusColor: Color {
        switch session.status.lowercased() {
        case "running": return .green
        case "pending": return .orange
        case "failed", "error": return .red
        case "terminating": return .gray
        default: return .gray
        }
    }

    private var typeColor: Color {
        switch session.sessionType.lowercased() {
        case "notebook": return .blue
        case "desktop": return .purple
        case "carta": return .teal
        case "contributed": return Color(.systemOrange)
        case "firefly": return .orange
        case "headless": return .gray
        default: return .secondary
        }
    }

    private var typeImageAsset: String? {
        switch session.sessionType.lowercased() {
        case "notebook": return "session-notebook"
        case "desktop": return "session-desktop"
        case "carta": return "session-carta"
        case "contributed": return "session-contributed"
        case "firefly": return "session-firefly"
        default: return nil
        }
    }

    private var typeIcon: String {
        switch session.sessionType.lowercased() {
        case "notebook": return "book.pages"
        case "desktop": return "desktopcomputer"
        case "carta": return "map"
        case "contributed": return "shippingbox"
        case "firefly": return "flame"
        case "headless": return "terminal"
        default: return "questionmark.square"
        }
    }

    private func formatTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateFormat = "MMM d, HH:mm"
            return display.string(from: date)
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateFormat = "MMM d, HH:mm"
            return display.string(from: date)
        }
        return isoString
    }
}
