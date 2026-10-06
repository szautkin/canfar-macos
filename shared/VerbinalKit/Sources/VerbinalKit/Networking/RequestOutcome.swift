// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// How a request to CADC or CANFAR ended, in the terms an assistant or the
/// person acts on: what it means, and whether asking again can help. The
/// one classification — the ledger, the session log, a reply's timing and a
/// search's error all read it (plan 23).
public enum RequestOutcome: String, Codable, Sendable, CaseIterable {
    case ok
    case timedOut
    case unreachable
    case offline
    case busy
    case serverError
    case signInNeeded
    case notAllowed
    case notFound
    case rejected
    case cancelled

    /// Whether asking again can help, and when.
    public enum Retry: String, Codable, Sendable {
        case now
        case later
        case afterSignIn
        case no

        /// "retry later".
        public var advice: String {
            switch self {
            case .now: "retry now"
            case .later: "retry later"
            case .afterSignIn: "retry after the person signs in"
            case .no: "change the request: asked again, it fails the same way"
            }
        }
    }

    /// An answer, by its HTTP status.
    public init(status: Int) {
        switch status {
        case 200..<400: self = .ok
        case 401: self = .signInNeeded
        case 403: self = .notAllowed
        case 404, 410: self = .notFound
        case 408: self = .timedOut
        case 429, 503: self = .busy
        case 400..<500: self = .rejected
        default: self = .serverError
        }
    }

    /// An answer to a request sent without credentials on purpose — a
    /// health probe: a 401 or 403 says the service answered and its data
    /// needs sign-in, not that the person must sign in (plan 30 N2).
    public init(anonymousStatus status: Int) {
        self = status == 401 || status == 403 ? .ok : RequestOutcome(status: status)
    }

    /// No answer, by the error that came instead.
    public init(error: Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        if let network = error as? NetworkError {
            switch network {
            case .unauthorized: self = .signInNeeded
            case .httpError(let status, _): self = RequestOutcome(status: status)
            case .invalidURL: self = .rejected
            case .invalidResponse: self = .serverError
            }
            return
        }
        guard let urlError = error as? URLError else {
            self = .unreachable
            return
        }
        switch urlError.code {
        case .timedOut:
            self = .timedOut
        case .cancelled:
            self = .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            self = .offline
        case .userAuthenticationRequired, .userCancelledAuthentication:
            self = .signInNeeded
        case .badURL, .unsupportedURL, .fileDoesNotExist:
            self = .rejected
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData,
             .zeroByteResource, .httpTooManyRedirects, .redirectToNonExistentLocation:
            self = .serverError
        default:
            // DNS, connect, TLS, a dropped connection: the service, or the
            // way to it, is not there.
            self = .unreachable
        }
    }

    public var isFailure: Bool { self != .ok }

    /// A failure that says the service itself is in trouble — not the
    /// person's sign-in, not the request, not this Mac's network.
    public var isServiceTrouble: Bool {
        switch self {
        case .timedOut, .unreachable, .busy, .serverError: true
        default: false
        }
    }

    /// Whether asking again can help; `nil` for an answer.
    public var retry: Retry? {
        switch self {
        case .ok: nil
        case .timedOut, .unreachable, .offline, .busy, .serverError: .later
        case .signInNeeded: .afterSignIn
        case .notAllowed, .notFound, .rejected: .no
        case .cancelled: .now
        }
    }

    /// What it means, after the service's name: "the CADC archive search
    /// did not answer in time — it is slow or down".
    public var meaning: String {
        switch self {
        case .ok: "answered"
        case .timedOut: "did not answer in time — it is slow or down"
        case .unreachable: "could not be reached — it, or the way to it, is down"
        case .offline: "could not be reached — this Mac has no network"
        case .busy: "is busy and asked to be asked later"
        case .serverError: "failed on its side"
        case .signInNeeded: "needs the person to sign in"
        case .notAllowed: "refused: this account is not allowed to do that"
        case .notFound: "has no such thing"
        case .rejected: "refused the request as it was made"
        case .cancelled: "was stopped before it answered"
        }
    }
}
