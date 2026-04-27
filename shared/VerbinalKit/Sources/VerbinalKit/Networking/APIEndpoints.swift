// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

public struct APIEndpoints: Sendable {
    public var loginBaseURL: String
    public var skahaBaseURL: String
    public var acBaseURL: String
    public var storageBaseURL: String
    /// CADC archive base — TAP, CAOM2 metadata, DataLink, packaging.
    /// Single root means changing CADC's host name happens in one place.
    public var archiveBaseURL: String
    /// External web URLs (browser-targeted, not REST).
    public var externalBaseURL: String
    /// Default cap on TAP MAXREC — large enough to cover normal browsing
    /// without breaking the server's response budget.
    public var tapMaxRecords: Int

    public init(
        loginBaseURL: String = "https://ws-cadc.canfar.net/ac",
        skahaBaseURL: String = "https://ws-uv.canfar.net/skaha",
        acBaseURL: String = "https://ws-uv.canfar.net/ac",
        storageBaseURL: String = "https://ws-uv.canfar.net/arc/nodes/home",
        archiveBaseURL: String = "https://ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca",
        externalBaseURL: String = "https://www.cadc-ccda.hia-iha.nrc-cnrc.gc.ca",
        tapMaxRecords: Int = 30000
    ) {
        self.loginBaseURL = loginBaseURL
        self.skahaBaseURL = skahaBaseURL
        self.acBaseURL = acBaseURL
        self.storageBaseURL = storageBaseURL
        self.archiveBaseURL = archiveBaseURL
        self.externalBaseURL = externalBaseURL
        self.tapMaxRecords = tapMaxRecords
    }

    public var loginURL: String { "\(loginBaseURL)/login" }
    public var whoAmIURL: String { "\(loginBaseURL)/whoami" }
    public func userURL(_ username: String) -> String { "\(loginBaseURL)/users/\(username)?idType=HTTP&detail=display" }

    public var sessionsURL: String { "\(skahaBaseURL)/v1/session" }
    public func sessionURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)" }
    public func sessionRenewURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)?action=renew" }
    public func sessionEventsURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)?view=events" }
    public func sessionLogsURL(_ id: String) -> String { "\(skahaBaseURL)/v1/session/\(id)?view=logs" }
    public var statsURL: String { "\(skahaBaseURL)/v1/session?view=stats" }

    public var imagesURL: String { "\(skahaBaseURL)/v1/image" }
    public var contextURL: String { "\(skahaBaseURL)/v1/context" }
    public var repositoryURL: String { "\(skahaBaseURL)/v1/repository" }

    public func storageURL(_ username: String) -> String { "\(storageBaseURL)/\(username)?limit=0" }

    // MARK: - CADC Archive (TAP / CAOM2 / DataLink)

    /// Synchronous TAP query endpoint (Argus). Accepts ADQL via POST.
    public var tapSyncURL: String { "\(archiveBaseURL)/argus/sync" }
    /// Per-observation CAOM2 metadata document. ID query: `caom:{collection}/{obsID}`.
    public var caom2MetaURL: String { "\(archiveBaseURL)/caom2ops/meta" }
    /// IVOA DataLink-1.1 (file/cutout/preview links). ID query: publisher URI.
    public var datalinkURL: String { "\(archiveBaseURL)/caom2ops/datalink" }
    /// Packaging endpoint for direct file downloads.
    public var caom2PkgURL: String { "\(archiveBaseURL)/caom2ops/pkg" }
    /// Target name resolver (Sesame-style → coordinates).
    public var targetResolverURL: String { "\(archiveBaseURL)/cadc-target-resolver/find" }

    /// Browser-facing CAOM2 UI observation viewer.
    public var caom2UIViewURL: String { "\(externalBaseURL)/caom2ui/view" }
    /// Legacy in-browser download manager.
    public var downloadManagerURL: String { "\(externalBaseURL)/downloadManager/download" }
}
