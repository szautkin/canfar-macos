// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// Frames of the pointable controls in one window or sheet.
private struct PointableAnchorsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct PointableModifier: ViewModifier {
    @Environment(UIPointerRegistry.self) private var registry: UIPointerRegistry?
    let target: UIPointerMatcher.Target

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: PointableAnchorsKey.self, value: .bounds) { [target.id: $0] }
            .onAppear { registry?.register(target) }
            .onDisappear { registry?.unregister(target.id) }
    }
}

/// Draws the current hint — a ring round the control and the agent's
/// words beside it — over everything in this window or sheet.
private struct PointerOverlayModifier: ViewModifier {
    @Environment(UIPointerRegistry.self) private var registry: UIPointerRegistry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(PointableAnchorsKey.self) { anchors in
            GeometryReader { proxy in
                if let hint = registry?.hint, let anchor = anchors[hint.targetID] {
                    let frame = proxy[anchor].insetBy(dx: -6, dy: -6)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 3)
                            .shadow(color: .accentColor.opacity(0.6), radius: 6)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                        if let message = hint.message {
                            Text(message)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor))
                                .frame(maxWidth: 320, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .offset(x: max(8, min(frame.minX, proxy.size.width - 330)),
                                        y: frame.maxY + 8 > proxy.size.height - 60 ? frame.minY - 52 : frame.maxY + 8)
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hint.serial)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(hint.message ?? ""))
                }
            }
        }
    }
}

extension View {
    /// Lets an agent point at this control (`point_at_ui`). `id` is stable
    /// and unlocalized; `label` is what the person reads on it.
    func pointable(_ id: String, label: String, screen: String) -> some View {
        modifier(PointableModifier(target: .init(id: id, label: label, screen: screen)))
    }

    /// Draws an agent's pointer hint for the pointable controls inside.
    /// Put it at the root of each window and sheet.
    func uiPointerOverlay() -> some View {
        modifier(PointerOverlayModifier())
    }
}
