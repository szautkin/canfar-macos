// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// How long Verbinal waits on CADC and CANFAR, said once. Every request
/// takes its patience from here, by what kind of call it is, so a change
/// reaches every call of that kind.
///
/// A request's timeout is how long it may go without a byte arriving, not
/// how long it may take in all: a large download that keeps arriving runs
/// as long as it needs.
///
/// The assistant's tools set deadlines of their own over some of these
/// calls (`withApplierTimeout`), so that a tool call always ends; those are
/// not the endpoints' patience and are not here.
public enum RequestTimeout {
    /// Signing in, and nearly every call after it: sessions, storage,
    /// archive searches and details, DataLink, target lookup. CADC's
    /// services take 30–50 s under load, and have been silent for longer.
    public static let standard: TimeInterval = 120

    /// Starting a session or a batch job: CADC waits on the cluster's
    /// Kubernetes API, 60–90 s when it is busy.
    public static let launch: TimeInterval = 180

    /// What the person waits on before anything shows: the stored sign-in
    /// checked at launch, the registry's list of services, the image
    /// registry. Long enough for a slow answer, short enough that a dead
    /// network is said so in half a minute.
    public static let lookup: TimeInterval = 30

    /// One probe of the service-health check: a service that has not
    /// answered in this long is reported down.
    public static let probe: TimeInterval = 15

    /// An upload or a download may stall this long.
    public static let transfer: TimeInterval = 300

    /// The longest an assistant waits for any answer (plan 30 L, the
    /// person's decision): its MCP client may give up at 60 s. Past it the
    /// call answers that it is still working, and the work carries on —
    /// on the activity bar — instead of being cut off.
    public static let answer: TimeInterval = 45

    /// A read tool's deadline: the standard timeout and 10 s more, so the
    /// request's own timeout — which names who did not answer — fires
    /// first (plan 23 L7). Below the router's read ceiling (150 s).
    public static let toolDeadline: TimeInterval = standard + 10
}
