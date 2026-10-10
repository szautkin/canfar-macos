// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import VerbinalKit

/// Batch jobs: the headless jobs CANFAR lists, and those it no longer does.
extension AppState {
    func makeListHeadlessJobsTool() -> ListHeadlessJobsTool {
        let service = self.headlessService
        return ListHeadlessJobsTool(fetch: {
            try await service.getHeadlessJobs()
        })
    }

    func makeGetHeadlessJobTool() -> GetHeadlessJobTool {
        let service = self.headlessService
        return GetHeadlessJobTool(fetch: {
            try await service.getHeadlessJobs()
        }, remembered: { [weak self] id in await self?.jobHistory.jobs.first { $0.id == id } })
    }

    func makeGetHeadlessJobLogsTool() -> GetHeadlessJobLogsTool {
        let service = self.headlessService
        return GetHeadlessJobLogsTool(fetch: { id in
            try await service.getLogs(id: id)
        }, isListed: { id in await Self.isListed(id, service) })
    }

    func makeGetHeadlessJobEventsTool() -> GetHeadlessJobEventsTool {
        let service = self.headlessService
        return GetHeadlessJobEventsTool(fetch: { id in
            try await service.getEvents(id: id)
        }, isListed: { id in await Self.isListed(id, service) })
    }
}
