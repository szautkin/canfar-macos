// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import AppKit
import Foundation
import VerbinalKit

/// Workflows: listing and reading workflow files.
extension AppState {
    func makeListWorkflowsTool() -> ListWorkflowsTool {
        ListWorkflowsTool(list: { [weak self] in
            await MainActor.run {
                guard let self else { return [] }
                return self.workflowStore.listBuiltIn() + self.workflowStore.listLocal()
            }
        })
    }

    func makeGetWorkflowTool() -> GetWorkflowTool {
        GetWorkflowTool(get: { [weak self] id in
            await MainActor.run { self?.workflowStore.get(id) }
        })
    }
}
