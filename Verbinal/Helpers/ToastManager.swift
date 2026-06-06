// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import Observation

/// Shared toast notification system for durable user feedback.
@Observable
@MainActor
final class ToastManager {
    var message: String?
    var isError = false
    private var dismissTask: Task<Void, Never>?

    func show(_ msg: String, isError: Bool = false, duration: TimeInterval = 4) {
        dismissTask?.cancel()
        self.message = msg
        self.isError = isError
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self.message = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        message = nil
    }
}

/// Overlay modifier that shows a toast banner at the bottom of the view.
struct ToastOverlay: ViewModifier {
    var toast: ToastManager

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = toast.message {
                HStack(spacing: 8) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? .red : .green)
                    Text(message)
                        .font(.caption)
                    Spacer()
                    Button { toast.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss notification")
                    .help("Dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .appAnimation(AppMotion.toast, value: message)
            }
        }
    }
}

extension View {
    func toast(_ manager: ToastManager) -> some View {
        modifier(ToastOverlay(toast: manager))
    }
}

// MARK: - Environment Key

private struct FITSToastKey: EnvironmentKey {
    static let defaultValue: ToastManager? = nil
}

extension EnvironmentValues {
    /// Optional ToastManager for FITS viewer components. Injected at FITSViewerRootView.
    var fitsToast: ToastManager? {
        get { self[FITSToastKey.self] }
        set { self[FITSToastKey.self] = newValue }
    }
}
