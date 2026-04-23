// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// A `TextField` with a debounced commit so rapid typing doesn't thrash the
/// filter+sort pipeline. Each change cancels any prior pending commit.
///
/// **External-reset hazard**: the field also watches `currentValue` so the
/// owning model can push an external change (e.g., `loadResults` clearing
/// filters). When that happens we must *also* cancel the in-flight debounce,
/// otherwise a 200 ms-stale draft can overwrite the just-cleared filter a
/// moment after reset. The `suppressNextCommit` flag prevents the subsequent
/// `onChange(of: draft)` — fired by our own sync assignment — from scheduling
/// a redundant commit back into the model.
struct DebouncedFilterField: View {
    let columnID: String
    let currentValue: String
    let onCommit: (String) -> Void
    var debounceMilliseconds: Int = 200

    @State private var draft: String = ""
    @State private var debounce: Task<Void, Never>?
    @State private var suppressNextCommit: Bool = false

    var body: some View {
        TextField("Filter…", text: $draft)
            .textFieldStyle(.plain)
            .font(.caption2)
            .onAppear {
                // Seed without triggering a commit back into the model.
                if draft != currentValue {
                    suppressNextCommit = true
                    draft = currentValue
                }
            }
            .onChange(of: currentValue) { _, new in
                // External reset — cancel any pending commit AND suppress the
                // commit that our own draft-sync assignment will queue next.
                guard draft != new else { return }
                debounce?.cancel()
                suppressNextCommit = true
                draft = new
            }
            .onChange(of: draft) { _, new in
                if suppressNextCommit {
                    suppressNextCommit = false
                    return
                }
                debounce?.cancel()
                let delay = debounceMilliseconds
                debounce = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled else { return }
                    onCommit(new)
                }
            }
    }
}
