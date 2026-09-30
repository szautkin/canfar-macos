// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// When an agent's change applies — the rule the app enforces and the
/// sentence every proposing tool's description ends with, in one place so
/// the two cannot disagree. (Tools once said a deletion "runs immediately
/// when auto-apply is on" though destructive changes never auto-apply.)
public enum AutoApplyPolicy {

    /// Whether a proposal of `verbClass` applies without the user.
    public static func appliesAtOnce(_ verbClass: VerbClass, autoApplyOn: Bool) -> Bool {
        switch verbClass {
        case .semanticWrite: return autoApplyOn
        case .destructive, .standingInstruction: return false
        case .read, .viewState, .proposalLifecycle, .undo: return false
        }
    }

    /// The sentence that ends a proposing tool's description; nil for a
    /// tool that does not propose.
    public static func toolSentence(for verbClass: VerbClass) -> String? {
        switch verbClass {
        case .semanticWrite:
            return "When it applies is the app's rule: with Auto-apply agent writes on (Settings ▸ AI Agent) at once, otherwise it waits in Pending until the user applies it — `get_current_view.autoApplyEnabled` says which."
        case .destructive:
            return "Destructive: it always waits in Pending for the user to approve, whatever Auto-apply says."
        case .standingInstruction:
            return "A standing instruction: what it says is read by every agent from now on, so it always waits in Pending for the user to approve, whatever Auto-apply says."
        case .read, .viewState, .proposalLifecycle, .undo:
            return nil
        }
    }

    /// Why a change of `verbClass` was applied at once or held, in words,
    /// for the session log (plan 23 A).
    public static func rule(for verbClass: VerbClass, appliedAtOnce: Bool) -> String {
        switch verbClass {
        case .semanticWrite:
            return appliedAtOnce ? "applied at once: Auto-apply is on and this is not a delete"
                                 : "waits in Pending: Auto-apply is off, so the person applies each change"
        case .destructive:
            return "waits in Pending: a delete always waits for the person, whatever Auto-apply says"
        case .standingInstruction:
            return "waits in Pending: what every later assistant is told always waits for the person"
        case .read, .viewState, .proposalLifecycle, .undo:
            return appliedAtOnce ? "applied at once" : "waits in Pending"
        }
    }

    /// `description` ending with the rule for `verbClass`.
    public static func describe(_ description: String, verbClass: VerbClass) -> String {
        guard let sentence = toolSentence(for: verbClass) else { return description }
        return description + " " + sentence
    }
}
