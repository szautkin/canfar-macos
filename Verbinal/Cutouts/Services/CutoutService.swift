// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation
import os.log
import VerbinalKit

/// One way of cutting one file: the file, who cuts it, how a cutout of it
/// is judged, and how large it will be. What the editor and an agent's
/// cutout tools work with; CADC's SODA service is one way, the complete
/// file on this computer another (D3).
protocol CutoutSource: Sendable {
    var method: CutoutMethod { get }
    var file: CutoutFile { get }
    /// The whole file's size, when known — what the estimate reads against.
    var wholeFileBytes: Int64? { get }
    /// Why this way cannot cut this file at all, or nil when it can.
    var unavailable: String? { get }
    /// The rules, and whatever only this way knows. The reasons are the answer.
    func check(_ spec: CutoutSpec) -> CutoutCheck
    func estimatedBytes(_ spec: CutoutSpec) -> Int64?
}

extension CutoutSource {
    var unavailable: String? { nil }

    /// The cutout an editor opens on — from the search, when it looked at
    /// this file — cut this way: a local file's suggestion said `soda`
    /// (QA N5), and a download_cutout left to it asked CADC.
    func suggest(_ hints: CutoutHints?) -> CutoutSpec {
        var spec = CutoutPrefill.suggest(file, hints: hints)
        spec.cutBy = method
        return spec
    }
}

/// A file CADC's SODA service can cut, as its DataLink answer describes it.
struct SodaCutoutSource: CutoutSource {
    let descriptor: SodaDescriptor
    let wholeFileBytes: Int64?

    var method: CutoutMethod { .soda }
    var file: CutoutFile { descriptor }

    /// SODA's rules are the common ones: it answers a refused cutout with a bare HTTP 400.
    func check(_ spec: CutoutSpec) -> CutoutCheck { CutoutRules.check(spec, against: descriptor) }
    func estimatedBytes(_ spec: CutoutSpec) -> Int64? { SodaRequest.estimatedBytes(descriptor, spec, wholeFile: wholeFileBytes) }
}

/// A cutout's files, in temporary places: the cutout, and the companions
/// cut with it (a weight map), each named by the cutout's key.
struct CutoutFiles: Sendable {
    let cutout: URL
    var companions: [URL] = []
}

/// Makes a cutout's file, one way. Research keeps every cutout the same
/// way; the maker is asked only for the step that differs: the bytes.
protocol CutoutMaker: Sendable {
    var method: CutoutMethod { get }
    /// The cutout (and companions) in temporary files; throws with the reason.
    func make(publisherID: String, spec: CutoutSpec) async throws -> CutoutFiles
}

/// What an observation's files can be cut by on CADC's side, and a SODA
/// cutout's file fetched.
actor CutoutService {
    private static let logger = Logger(subsystem: "com.codebg.Verbinal", category: "Cutouts")

    private let session: URLSession
    private let endpoints: APIEndpoints
    private let caom2: CAOM2Service
    private let downloads: DownloadService

    init(session: URLSession = .shared, endpoints: APIEndpoints = TAPConfig.endpoints,
         caom2: CAOM2Service = CAOM2Service(), downloads: DownloadService = DownloadService()) {
        self.session = session
        self.endpoints = endpoints
        self.caom2 = caom2
        self.downloads = downloads
    }

    /// The files CADC can cut, and — when it can cut none — why its answer
    /// offered no way to.
    struct Options: Sendable {
        let sources: [SodaCutoutSource]
        let problems: [String]
        /// Every file of the observation, by artifact ID — what a local cut's
        /// companions are looked for among.
        var artifacts: [String] = []
    }

    func options(publisherID: String) async -> Options {
        async let artifacts = artifactSizes(publisherID: publisherID)
        let parse: SodaDescriptorParser.Parse
        do {
            parse = SodaDescriptorParser.parse(try await dataLinkDocument(publisherID: publisherID))
        } catch {
            return Options(sources: [], problems: ["DataLink could not be read: \(error.localizedDescription)"],
                           artifacts: await artifacts.keys.sorted())
        }
        let sizes = await artifacts
        guard !parse.descriptors.isEmpty else { return Options(sources: [], problems: parse.passedOver, artifacts: sizes.keys.sorted()) }
        return Options(sources: parse.descriptors.map { SodaCutoutSource(descriptor: $0, wholeFileBytes: sizes[$0.artifactID].flatMap { $0 > 0 ? $0 : nil }) },
                       problems: [], artifacts: sizes.keys.sorted())
    }

    /// The cutout, fetched to a temporary file — against the file's
    /// descriptor as DataLink describes it now: a cutout can be fetched long
    /// after it was chosen.
    func fetch(publisherID: String, spec: CutoutSpec) async throws -> URL {
        let options = await options(publisherID: publisherID)
        guard let source = options.sources.first(where: { $0.descriptor.artifactID == spec.artifactID }) else {
            throw CutoutFailure.noService(options.problems.first ?? "CADC offers no cutout service for \(spec.artifactID)")
        }
        let url: URL
        do {
            url = try SodaRequest.url(source.descriptor, spec)
        } catch {
            guard case .refused(let issue) = error else { throw CutoutFailure.refused("the cutout was refused") }
            throw CutoutFailure.refused(issue.message)
        }
        Self.logger.info("SODA cutout of \(spec.artifactID, privacy: .public): \(spec.summary, privacy: .public)")
        return try await downloads.downloadToTemp(url: url, suggestedFilename: spec.fileName, publisherID: publisherID).tempURL
    }

    /// The whole DataLink answer — service descriptors included, which the
    /// `downloads-only` request leaves out.
    private func dataLinkDocument(publisherID: String) async throws -> Data {
        guard var components = URLComponents(string: endpoints.datalinkURL) else {
            throw CutoutFailure.noService("the DataLink address is not valid")
        }
        components.queryItems = [URLQueryItem(name: "id", value: publisherID)]
        guard let url = components.url else { throw CutoutFailure.noService("the DataLink address is not valid") }
        var request = URLRequest(url: url)
        request.setValue("application/x-votable+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = RequestTimeout.standard
        let (data, response) = try await session.recordedData(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CutoutFailure.noService("DataLink answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    /// Each of the observation's files, by artifact ID, with its size when
    /// CAOM2 gives one (0 when not); empty when CAOM2 cannot be read.
    private func artifactSizes(publisherID: String) async -> [String: Int64] {
        guard let observation = try? await caom2.fetch(publisherID: publisherID) else { return [:] }
        var sizes: [String: Int64] = [:]
        for plane in observation.planes {
            for artifact in plane.artifacts { sizes[artifact.uri] = artifact.contentLength ?? 0 }
        }
        return sizes
    }
}

/// Why a cutout could not be made.
enum CutoutFailure: LocalizedError, Equatable {
    /// CADC offers no way to cut the file.
    case noService(String)
    /// The rules refused it.
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .noService(let why), .refused(let why): return why
        }
    }
}

/// A cutout cut on CADC's side, then downloaded.
struct SodaCutoutMaker: CutoutMaker {
    let service: CutoutService
    var method: CutoutMethod { .soda }

    func make(publisherID: String, spec: CutoutSpec) async throws -> CutoutFiles {
        CutoutFiles(cutout: try await service.fetch(publisherID: publisherID, spec: spec))
    }
}
