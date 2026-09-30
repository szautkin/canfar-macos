// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// A password field with Show and Hide: the eye shows what was typed and
/// hides it again. The text is the same either way, and the cursor goes
/// back into the field after the switch, so typing carries on. Hidden when
/// it first appears (`revealed` is there for tests).
///
/// `focus` and `field` are the form's own focus state, so the form still
/// decides where the cursor lands (the login sheet puts it here when the
/// username is remembered).
struct PasswordField<Focus: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let focus: FocusState<Focus?>.Binding
    let field: Focus
    var onSubmit: () -> Void = {}

    @State private var isRevealed: Bool

    init(_ title: LocalizedStringKey, text: Binding<String>, focus: FocusState<Focus?>.Binding, field: Focus,
         revealed: Bool = false, onSubmit: @escaping () -> Void = {}) {
        self.title = title
        _text = text
        self.focus = focus
        self.field = field
        self.onSubmit = onSubmit
        _isRevealed = State(initialValue: revealed)
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(title, text: $text)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
            .focused(focus, equals: field)
            .onSubmit(onSubmit)

            Button {
                isRevealed.toggle()
                // The field just swapped for its twin; the cursor follows it.
                Task { @MainActor in focus.wrappedValue = field }
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? Text("Hide password") : Text("Show password"))
            .accessibilityLabel(isRevealed ? Text("Hide password") : Text("Show password"))
        }
    }
}
