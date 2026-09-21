// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

public actor NetworkClient {
    private let session: URLSession
    public private(set) var token: String?
    /// Hosts the bearer token may be attached to. Token is *not* sent to any
    /// other host — important defense against forwarding the user's CADC
    /// credential to a third-party `accessURL` returned by DataLink or VOSpace.
    /// Hostnames are matched suffix-style (so `ws.cadc-ccda.hia-iha.nrc-cnrc.gc.ca`
    /// matches the catch-all `cadc-ccda.hia-iha.nrc-cnrc.gc.ca`); empty list
    /// means "send to nothing", which is the safe default for clients that
    /// haven't configured an allow-list.
    public private(set) var trustedAuthHostSuffixes: [String]

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    /// Optional callback invoked when a request returns 401 — the host
    /// surface (`AppState`) plugs in a token refresh / re-prompt here.
    /// Returns `true` if the client should retry the original request once;
    /// `false` if the 401 should propagate as `NetworkError.unauthorized`.
    public typealias UnauthorizedHandler = @Sendable () async -> Bool
    private var onUnauthorized: UnauthorizedHandler?

    public init(
        session: URLSession = .shared,
        trustedAuthHostSuffixes: [String] = NetworkClient.defaultCADCHosts
    ) {
        self.session = session
        self.trustedAuthHostSuffixes = trustedAuthHostSuffixes
    }

    public func setUnauthorizedHandler(_ handler: UnauthorizedHandler?) {
        self.onUnauthorized = handler
    }

    /// Default allow-list — the CADC + CANFAR domain families. Anything else
    /// (including DataLink redirects to partner archives) is treated as
    /// untrusted: requests still execute, but without our token.
    public static let defaultCADCHosts: [String] = [
        "cadc-ccda.hia-iha.nrc-cnrc.gc.ca",
        "canfar.net",
    ]

    /// Build the bearer-token host allow-list from effective endpoints,
    /// always unioned with the classic CADC/CANFAR families so a partial
    /// override cannot lock the app out of the defaults mid-session.
    public static func trustedHostSuffixes(from endpoints: APIEndpoints) -> [String] {
        var hosts = Set(defaultCADCHosts.map { $0.lowercased() })
        let urls = [
            endpoints.loginBaseURL, endpoints.skahaBaseURL, endpoints.acBaseURL,
            endpoints.storageBaseURL, endpoints.registryBaseURL,
            endpoints.archiveBaseURL, endpoints.externalBaseURL,
        ]
        for urlString in urls {
            if let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty {
                hosts.insert(host)
            }
        }
        return hosts.sorted()
    }

    // MARK: - Mutable configuration
    //
    // Concurrency contract: `NetworkClient` is an `actor`, so the config
    // mutators below and `execute` are serialized through the actor's
    // executor — there is no torn read/write. What is *not* promised is a
    // happens-before relationship between a config update and an in-flight
    // request: a `setToken` issued concurrently with an outstanding `get`/
    // `post` may or may not be observed by that request, since the request
    // may already have stamped (or skipped) its Authorization header before
    // the write is serialized. The token a request uses always reflects one
    // of the serialized writes — never a partially-applied value — but
    // callers must not assume an awaited mutator retroactively affects
    // requests that were started before it. To order an update ahead of a
    // request, `await` the mutator before issuing the request.

    /// Set the bearer token attached to requests bound for trusted hosts.
    /// See the concurrency contract above: ordering relative to in-flight
    /// requests is not guaranteed; `await` this before issuing a request
    /// that must see the new token.
    public func setToken(_ token: String?) {
        self.token = token
    }

    /// Replace the host allow-list the bearer token may be attached to.
    /// See the concurrency contract above for ordering relative to in-flight
    /// requests.
    public func setTrustedAuthHostSuffixes(_ hosts: [String]) {
        self.trustedAuthHostSuffixes = hosts
    }

    /// Atomically set the token and host allow-list together. Because both
    /// writes happen within a single actor-isolated call, no request can
    /// observe one without the other (e.g. a new token paired with a stale
    /// allow-list). Prefer this when both values change as a unit, such as on
    /// sign-in. Ordering relative to *already in-flight* requests is still not
    /// guaranteed — see the concurrency contract above.
    public func configure(token: String?, trustedAuthHostSuffixes hosts: [String]) {
        self.token = token
        self.trustedAuthHostSuffixes = hosts
    }

    /// Whether the bearer token would be attached to a request to `host`.
    /// Exposed for callers that need to decide whether to even make a call
    /// (e.g., authenticated endpoints).
    public func isTrustedAuthHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return trustedAuthHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    // MARK: - HTTP Methods

    /// `allowAuthRetry: false` opts a request out of the `onUnauthorized`
    /// interceptor. REQUIRED for the auth flow's own requests (/whoami
    /// validation, /login): the interceptor's recovery path issues those
    /// very requests, so letting them re-enter it on 401 recurses without
    /// bound — the launch-time symptom is an app stuck on "Checking
    /// authentication…" hammering /whoami forever.
    public func get(
        _ urlString: String,
        accept: String? = nil,
        additionalHeaders: [String: String]? = nil,
        timeout: TimeInterval = 60,
        allowAuthRetry: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "GET", timeout: timeout)
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        if let additionalHeaders {
            for (k, v) in additionalHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }
        return try await execute(request, allowAuthRetry: allowAuthRetry)
    }

    public func getText(_ urlString: String, timeout: TimeInterval = 60, allowAuthRetry: Bool = true) async throws -> String {
        let (data, _) = try await get(urlString, timeout: timeout, allowAuthRetry: allowAuthRetry)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func getJSON<T: Decodable>(_ urlString: String, type: T.Type) async throws -> T {
        let (data, _) = try await get(urlString, accept: "application/json")
        return try Self.jsonDecoder.decode(T.self, from: data)
    }

    public func post(
        _ urlString: String,
        formData: [String: String],
        headers: [String: String]? = nil,
        timeout: TimeInterval = 60,
        allowAuthRetry: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        try await post(
            urlString,
            formPairs: formData.map { ($0.key, $0.value) },
            headers: headers,
            timeout: timeout,
            allowAuthRetry: allowAuthRetry
        )
    }

    /// POST with ordered `(key, value)` pairs — duplicate keys allowed.
    /// Skaha headless launches require multi-value form fields (e.g.
    /// `env=KEY1=VAL1` repeated per environment variable, matching the
    /// canonical Python `canfar` client). The dictionary variant above
    /// can't express that; this one is the single source of truth and
    /// the dictionary form delegates to it.
    public func post(
        _ urlString: String,
        formPairs: [(String, String)],
        headers: [String: String]? = nil,
        // CADC services routinely take 30–50s under load (their tomcat
        // pools serialise quota / catalogue lookups against K8s). 60s
        // is a patience floor that lets honest slowness through while
        // still bounding pathological hangs.
        timeout: TimeInterval = 60,
        allowAuthRetry: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "POST", timeout: timeout)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = formPairs
            .map { key, value in
                "\(Self.formEncode(key))=\(Self.formEncode(value))"
            }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        if let headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        return try await execute(request, allowAuthRetry: allowAuthRetry)
    }

    /// Stricter than `.urlQueryAllowed`: also encodes `&`, `=`, `+`, `?`
    /// so they survive transit through a form-encoded body. Without this
    /// an env value like `FOO=bar&baz` would get parsed by the server as
    /// two separate fields.
    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.subtract(CharacterSet(charactersIn: "&=+?"))
        return set
    }()

    private static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }

    /// POST with a raw body (e.g. VOSpace setNode XML documents — the
    /// UpdateNodeAction is a POST, unlike CreateNodeAction's PUT).
    public func post(
        _ urlString: String,
        body: Data,
        contentType: String,
        timeout: TimeInterval = 60
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "POST", timeout: timeout)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await execute(request)
    }

    public func delete(_ urlString: String) async throws -> HTTPURLResponse {
        let request = try makeRequest(urlString, method: "DELETE")
        let (_, response) = try await execute(request)
        return response
    }

    public func put(
        _ urlString: String,
        body: Data,
        contentType: String,
        timeout: TimeInterval = 300
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "PUT", timeout: timeout)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await execute(request)
    }

    /// Byte-progress callback shared by streaming uploads and downloads.
    /// `bytesTotal` may be a caller-supplied fallback when the session
    /// reports `NSURLSessionTransferSizeUnknown`.
    public typealias TransferProgressHandler = @Sendable (_ bytesTransferred: Int64, _ bytesTotal: Int64) -> Void

    /// Backward-compatible alias — prefer `TransferProgressHandler`.
    public typealias UploadProgressHandler = TransferProgressHandler

    /// Stream a file from disk via `PUT`. Uses `URLSession.upload(for:fromFile:)`
    /// so the body is read incrementally instead of being materialised into
    /// memory. Progress uses the async overload's per-request task delegate
    /// (`didSendBodyData`). Task cancellation cancels the transfer.
    public func putFile(
        _ urlString: String,
        fileURL: URL,
        contentType: String,
        timeout: TimeInterval = 300,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(urlString, method: "PUT", timeout: timeout)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let fileSize: Int64 = {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                return Int64(size)
            }
            return (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?
                .int64Value ?? 0
        }()

        if let onProgress, fileSize > 0 {
            onProgress(0, fileSize)
        }

        return try await retryUnauthorized(original: request) {
            try await self.putFileOnce(
                request: $0,
                fileURL: fileURL,
                fileSize: fileSize,
                onProgress: onProgress
            )
        }
    }

    /// Single PUT attempt — extracted so a 401 can restamp the bearer
    /// token and retry without duplicating the stream/progress setup.
    private func putFileOnce(
        request: URLRequest,
        fileURL: URL,
        fileSize: Int64,
        onProgress: TransferProgressHandler?
    ) async throws -> (Data, HTTPURLResponse) {
        let delegate = onProgress.map {
            TransferProgressTaskDelegate(fallbackTotal: fileSize, onProgress: $0)
        }
        let data: Data
        let response: URLResponse
        do {
            if let delegate {
                (data, response) = try await session.upload(
                    for: request,
                    fromFile: fileURL,
                    delegate: delegate
                )
            } else {
                (data, response) = try await session.upload(for: request, fromFile: fileURL)
            }
        } catch {
            throw mapTransferCancellation(error)
        }
        return try validateTransferResponse(data: data, response: response)
    }

    /// Stream a remote file to a temporary URL via `URLSessionDownloadTask`.
    /// Avoids buffering the whole payload in RAM (the old `get` + `Data.write`
    /// path). When `onProgress` is set, uses a dedicated session + download
    /// delegate so `didWriteData` actually fires — the async convenience
    /// `download(for:delegate:)` suppresses those callbacks (and KVO on
    /// `task.progress` often only jumps at completion).
    /// `expectedTotal` seeds the bar when `Content-Length` is missing
    /// (e.g. VOSpace `#length` from the listing).
    public func downloadFile(
        _ urlString: String,
        timeout: TimeInterval = 300,
        expectedTotal: Int64 = 0,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> (tempURL: URL, response: HTTPURLResponse) {
        let request = try makeRequest(urlString, method: "GET", timeout: timeout)
        return try await retryUnauthorized(original: request) {
            try await self.downloadFileOnce(
                request: $0,
                expectedTotal: expectedTotal,
                onProgress: onProgress
            )
        }
    }

    private func downloadFileOnce(
        request: URLRequest,
        expectedTotal: Int64,
        onProgress: TransferProgressHandler?
    ) async throws -> (tempURL: URL, response: HTTPURLResponse) {
        let location: URL
        let response: URLResponse
        do {
            if let onProgress {
                if expectedTotal > 0 { onProgress(0, expectedTotal) }
                (location, response) = try await downloadWithProgressDelegate(
                    request,
                    expectedTotal: expectedTotal,
                    onProgress: onProgress
                )
            } else {
                (location, response) = try await session.download(for: request)
            }
        } catch {
            throw mapTransferCancellation(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        if http.statusCode == 401 {
            throw NetworkError.unauthorized
        }
        if http.statusCode >= 400 {
            let body = (try? String(contentsOf: location, encoding: .utf8)).map { String($0.prefix(500)) } ?? ""
            throw NetworkError.httpError(http.statusCode, body)
        }
        return (location, http)
    }

    /// Classic download-task session — required for live `didWriteData`.
    /// Copies `protocolClasses` from the client's session so unit tests'
    /// `MockURLProtocol` still intercepts.
    private func downloadWithProgressDelegate(
        _ request: URLRequest,
        expectedTotal: Int64,
        onProgress: @escaping TransferProgressHandler
    ) async throws -> (URL, URLResponse) {
        let protocolClasses = session.configuration.protocolClasses
        let timeout = request.timeoutInterval
        let controller = ProgressDownloadController(
            fallbackTotal: expectedTotal,
            onProgress: onProgress,
            protocolClasses: protocolClasses,
            timeout: timeout
        )
        return try await withTaskCancellationHandler {
            try await controller.start(request)
        } onCancel: {
            controller.cancel()
        }
    }

    private func mapTransferCancellation(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        return error
    }

    private func validateTransferResponse(data: Data, response: URLResponse) throws -> (Data, HTTPURLResponse) {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw NetworkError.unauthorized
        }
        if httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.httpError(httpResponse.statusCode, body)
        }
        return (data, httpResponse)
    }

    /// Restamp Authorization from the current token and retry `operation`
    /// once after the host's `onUnauthorized` handler refreshes credentials.
    /// Streaming PUT/GET bypass `execute`, so they share this helper instead
    /// of duplicating the 401 interceptor.
    private func retryUnauthorized<T>(
        original request: URLRequest,
        allowAuthRetry: Bool = true,
        operation: (URLRequest) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(request)
        } catch let error as NetworkError where error.isUnauthorized && allowAuthRetry {
            if let handler = onUnauthorized, await handler() {
                return try await operation(restamped(request))
            }
            throw error
        }
    }

    private func restamped(_ request: URLRequest) -> URLRequest {
        var retried = request
        if let url = retried.url, isTrustedAuthHost(url.host),
           let token, !token.isEmpty {
            retried.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            retried.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return retried
    }

    // MARK: - Private

    private func makeRequest(_ urlString: String, method: String, timeout: TimeInterval = 60) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout

        // Attach the bearer token *only* to hosts in the trusted allow-list.
        // DataLink/VOSpace responses can redirect to partner archives whose
        // hostnames we didn't pre-approve; sending CADC credentials there
        // would leak the user's token cross-origin.
        if let token, !token.isEmpty, isTrustedAuthHost(url.host) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func execute(_ request: URLRequest, allowAuthRetry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            // Give the auth-lifecycle host one chance to refresh the token
            // (or surface a re-login UI) before we propagate the failure.
            // The handler returns true if a retry is worth attempting.
            if allowAuthRetry, let handler = onUnauthorized, await handler() {
                return try await execute(restamped(request), allowAuthRetry: false)
            }
            throw NetworkError.unauthorized
        }
        if httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NetworkError.httpError(httpResponse.statusCode, body)
        }
        return (data, httpResponse)
    }
}

/// Per-request delegate for async `upload(for:fromFile:delegate:)`.
/// Upload still delivers `didSendBodyData` on many OS versions; KVO on
/// `task.progress` covers the cases where it does not.
private final class TransferProgressTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let fallbackTotal: Int64
    private let onProgress: NetworkClient.TransferProgressHandler
    private var progressObservation: NSKeyValueObservation?

    init(fallbackTotal: Int64, onProgress: @escaping NetworkClient.TransferProgressHandler) {
        self.fallbackTotal = fallbackTotal
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        progressObservation = task.progress.observe(
            \.completedUnitCount,
            options: [.new]
        ) { [weak self] progress, _ in
            guard let self else { return }
            let completed = progress.completedUnitCount
            let progressTotal = progress.totalUnitCount
            let expected =
                (progressTotal > 0 && progressTotal < Int64.max / 4)
                ? progressTotal
                : self.fallbackTotal
            self.report(transferred: completed, expected: expected)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        report(transferred: totalBytesSent, expected: totalBytesExpectedToSend)
    }

    private func report(transferred: Int64, expected: Int64) {
        let total = expected > 0 ? expected : fallbackTotal
        onProgress(transferred, total > 0 ? max(total, transferred) : 0)
    }
}

/// Owns a one-shot ephemeral `URLSession` + download task so
/// `didWriteData` is delivered (unlike `URLSession.download(for:delegate:)`).
private final class ProgressDownloadController: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let fallbackTotal: Int64
    private let onProgress: NetworkClient.TransferProgressHandler
    private let protocolClasses: [AnyClass]?
    private let timeout: TimeInterval

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var movedURL: URL?
    private var finished = false

    init(
        fallbackTotal: Int64,
        onProgress: @escaping NetworkClient.TransferProgressHandler,
        protocolClasses: [AnyClass]?,
        timeout: TimeInterval
    ) {
        self.fallbackTotal = fallbackTotal
        self.onProgress = onProgress
        self.protocolClasses = protocolClasses
        self.timeout = timeout
    }

    func start(_ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()

            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = protocolClasses
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            // `delegateQueue: nil` → URLSession creates a serial queue; callbacks
            // are not on MainActor (UI hop happens in StorageBrowserModel).
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: request)

            self.lock.lock()
            self.session = session
            self.task = task
            self.lock.unlock()

            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        let session = self.session
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : fallbackTotal
        onProgress(totalBytesWritten, expected > 0 ? max(expected, totalBytesWritten) : 0)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Temp download location is deleted when this callback returns —
        // move it under our control first.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbinal-dl-\(UUID().uuidString)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            lock.lock()
            movedURL = dest
            lock.unlock()
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let fileURL = movedURL
        lock.unlock()
        guard let fileURL else {
            finish(.failure(NetworkError.invalidResponse))
            return
        }
        guard let response = task.response else {
            finish(.failure(NetworkError.invalidResponse))
            return
        }
        finish(.success((fileURL, response)))
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        switch result {
        case .success(let value):
            cont?.resume(returning: value)
        case .failure(let error):
            cont?.resume(throwing: error)
        }
    }
}

public enum NetworkError: LocalizedError, Sendable {
    case invalidURL(String)
    case invalidResponse
    case unauthorized
    case httpError(Int, String)

    public var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .invalidResponse: return "Invalid server response"
        case .unauthorized: return "Authentication required"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        }
    }
}
