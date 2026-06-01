// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import XCTest
@testable import Verbinal

@MainActor
final class ExportServiceTests: XCTestCase {

    // MARK: - Test helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbinal-export-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeObservationStore() -> ObservationStore {
        ObservationStore(fileName: "test_export_obs_\(UUID().uuidString).json")
    }

    private func makeNoteStore() -> ObservationNoteStore {
        ObservationNoteStore(fileName: "test_export_notes_\(UUID().uuidString).json")
    }

    private func makeSavedQueryStore() -> SavedQueryStore {
        SavedQueryStore(fileName: "test_export_saved_\(UUID().uuidString).json")
    }

    private func makeRecentSearchStore() -> RecentSearchStore {
        RecentSearchStore(fileName: "test_export_recent_\(UUID().uuidString).json")
    }

    private func sampleObservation(publisherID: String = "ivo://cadc.nrc.ca/CFHT?2468000") -> DownloadedObservation {
        DownloadedObservation(
            publisherID: publisherID,
            collection: "CFHT",
            observationID: "2468000",
            targetName: "M31",
            instrument: "MegaCam",
            filter: "r.MP9601",
            ra: "10.68",
            dec: "41.27",
            startDate: "59000.0",
            calLevel: "2",
            localPath: "/tmp/fake/2468000.fits"
        )
    }

    override func tearDown() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = appSupport?.appendingPathComponent("Verbinal") {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("test_export_") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        // Clean up temp export dirs
        let tmpRoot = FileManager.default.temporaryDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(at: tmpRoot, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasPrefix("verbinal-export-tests-") {
            try? FileManager.default.removeItem(at: url)
        }
        super.tearDown()
    }

    // MARK: - ResearchExporter.itemCountLabel (pure function)

    func testItemCountLabelNoNotes() {
        XCTAssertEqual(ResearchExporter.itemCountLabel(observations: 0, notes: 0), "0 observations")
        XCTAssertEqual(ResearchExporter.itemCountLabel(observations: 1, notes: 0), "1 observation")
        XCTAssertEqual(ResearchExporter.itemCountLabel(observations: 5, notes: 0), "5 observations")
    }

    func testItemCountLabelWithNotes() {
        XCTAssertEqual(ResearchExporter.itemCountLabel(observations: 1, notes: 1), "1 observation, 1 note")
        XCTAssertEqual(ResearchExporter.itemCountLabel(observations: 12, notes: 3), "12 observations, 3 notes")
    }

    // MARK: - ResearchExporter.export

    func testResearchExportProducesJSONAndMarkdown() async throws {
        let obsStore = makeObservationStore()
        let noteStore = makeNoteStore()
        obsStore.save(sampleObservation())

        let exporter = ResearchExporter(observationStore: obsStore, noteStore: noteStore)
        let output = try await exporter.export(options: ExportOptions())

        XCTAssertNotNil(output.jsonFiles["observations.json"], "Should contain observations.json")
        XCTAssertNotNil(output.jsonFiles["notes.json"], "Should contain notes.json even when empty")
        XCTAssertNotNil(output.markdownFiles["notes.md"], "Should contain notes.md")
        XCTAssertEqual(output.itemCounts["observations"], 1)
        XCTAssertEqual(output.itemCounts["notes"], 0)
    }

    func testResearchExportOmitsNotesWhenOptionDisabled() async throws {
        let obsStore = makeObservationStore()
        let noteStore = makeNoteStore()
        obsStore.save(sampleObservation())

        let exporter = ResearchExporter(observationStore: obsStore, noteStore: noteStore)
        var options = ExportOptions()
        options.includeNotes = false
        let output = try await exporter.export(options: options)

        XCTAssertNil(output.jsonFiles["notes.json"], "Notes JSON should be omitted")
        XCTAssertNil(output.markdownFiles["notes.md"], "Notes MD should be omitted")
        XCTAssertNotNil(output.jsonFiles["observations.json"], "Observations should still be present")
    }

    func testResearchExportNotesMarkdownContainsObservationSections() async throws {
        let obsStore = makeObservationStore()
        let noteStore = makeNoteStore()
        let obs = sampleObservation()
        obsStore.save(obs)

        let note = ObservationNote(
            publisherID: obs.publisherID,
            text: "Great seeing on this night. Astrometry looks clean.",
            rating: 4,
            tags: ["usable", "astrometry"]
        )
        noteStore.save(note)

        let exporter = ResearchExporter(observationStore: obsStore, noteStore: noteStore)
        let output = try await exporter.export(options: ExportOptions())

        let markdown = output.markdownFiles["notes.md"] ?? ""
        XCTAssertTrue(markdown.contains("# Research Notes"))
        XCTAssertTrue(markdown.contains("M31"))
        XCTAssertTrue(markdown.contains("CFHT"))
        XCTAssertTrue(markdown.contains("★★★★☆"), "4-star rating should render")
        XCTAssertTrue(markdown.contains("`usable`"), "Tags should be code-quoted")
        XCTAssertTrue(markdown.contains("Great seeing"))
    }

    func testResearchExportAttachesFilesWhenOptionEnabled() async throws {
        let obsStore = makeObservationStore()
        let noteStore = makeNoteStore()

        // Create a real temporary file the exporter can attach
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-fits-\(UUID().uuidString).fits")
        try "SIMPLE  =                    T".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        var obs = sampleObservation()
        obs.localPath = tmpFile.path
        obsStore.save(obs)

        let exporter = ResearchExporter(observationStore: obsStore, noteStore: noteStore)
        var options = ExportOptions()
        options.includeFileCopies = true
        let output = try await exporter.export(options: options)

        XCTAssertEqual(output.attachedFiles.count, 1)
        XCTAssertEqual(output.attachedFiles.first?.lastPathComponent, tmpFile.lastPathComponent)
    }

    // MARK: - SearchExporter.export

    func testSearchExportProducesJSONAndMarkdown() async throws {
        let saved = makeSavedQueryStore()
        let recent = makeRecentSearchStore()
        saved.save(SavedQuery(name: "All M31", adql: "SELECT * FROM caom2.Observation WHERE targetName = 'M31'"))

        let exporter = SearchExporter(savedQueryStore: saved, recentSearchStore: recent)
        let output = try await exporter.export(options: ExportOptions())

        XCTAssertNotNil(output.jsonFiles["saved_queries.json"])
        XCTAssertNotNil(output.jsonFiles["recent_searches.json"])
        XCTAssertNotNil(output.markdownFiles["queries.md"])
        XCTAssertEqual(output.itemCounts["saved_queries"], 1)
    }

    func testSearchExportMarkdownContainsADQLCodeBlock() async throws {
        let saved = makeSavedQueryStore()
        let recent = makeRecentSearchStore()
        saved.save(SavedQuery(name: "M31 All", adql: "SELECT * FROM caom2.Observation WHERE targetName = 'M31'"))

        let exporter = SearchExporter(savedQueryStore: saved, recentSearchStore: recent)
        let output = try await exporter.export(options: ExportOptions())

        let markdown = output.markdownFiles["queries.md"] ?? ""
        XCTAssertTrue(markdown.contains("```sql"), "Markdown should contain fenced SQL block")
        XCTAssertTrue(markdown.contains("SELECT * FROM caom2.Observation"), "ADQL query should appear")
        XCTAssertTrue(markdown.contains("# Search Queries"))
    }

    func testSearchExportOmitsRecentWhenOptionDisabled() async throws {
        let saved = makeSavedQueryStore()
        let recent = makeRecentSearchStore()
        saved.save(SavedQuery(name: "q", adql: "SELECT 1"))

        let exporter = SearchExporter(savedQueryStore: saved, recentSearchStore: recent)
        var options = ExportOptions()
        options.includeSearchHistory = false
        let output = try await exporter.export(options: options)

        XCTAssertNotNil(output.jsonFiles["saved_queries.json"])
        XCTAssertNil(output.jsonFiles["recent_searches.json"])
        XCTAssertNil(output.itemCounts["recent_searches"])
    }

    // MARK: - ExportService.exportAll — bundle layout

    func testExportAllCreatesBundleStructure() async throws {
        let obsStore = makeObservationStore()
        let noteStore = makeNoteStore()
        obsStore.save(sampleObservation())

        let exporter = ResearchExporter(observationStore: obsStore, noteStore: noteStore)
        let service = ExportService()
        let tmpDir = makeTempDir()

        let bundleURL = await service.exportAll(to: tmpDir, modules: [exporter])
        guard let bundleURL else {
            XCTFail("exportAll returned nil — lastError=\(service.lastError ?? "nil")")
            return
        }

        // Expect manifest.json + README.md + research/ subdirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("research/observations.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("research/notes.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("research/notes.md").path))
        XCTAssertEqual(service.lastExportURL, bundleURL)
        XCTAssertFalse(service.isExporting)
    }

    func testExportAllManifestClaudeHintsAreDerivedFromActualFiles() async throws {
        let obsStore = makeObservationStore()
        let noteStore = makeNoteStore()
        obsStore.save(sampleObservation())

        let exporter = ResearchExporter(observationStore: obsStore, noteStore: noteStore)
        let service = ExportService()
        let tmpDir = makeTempDir()

        let bundleURL = await service.exportAll(to: tmpDir, modules: [exporter])
        guard let bundleURL else { return XCTFail("exportAll failed") }

        let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ExportManifest.self, from: manifestData)

        XCTAssertEqual(manifest.appName, "Verbinal")
        XCTAssertEqual(manifest.modules.count, 1)
        XCTAssertEqual(manifest.modules.first?.id, "research")
        XCTAssertEqual(manifest.modules.first?.displayName, "Research")
        XCTAssertNotNil(manifest.claudeHints.primaryContext, "Claude should be pointed at the markdown file")
        XCTAssertTrue(manifest.claudeHints.primaryContext?.hasSuffix(".md") ?? false)
        XCTAssertNotNil(manifest.claudeHints.metadataSchema, "Claude should be pointed at a JSON schema")
        XCTAssertTrue(manifest.claudeHints.metadataSchema?.hasSuffix(".json") ?? false)
        XCTAssertEqual(manifest.claudeHints.readMeFirst, "README.md")
    }

    func testExportAllWithMultipleModulesListsAllFiles() async throws {
        let obsStore = makeObservationStore()
        let noteStore = makeNoteStore()
        let saved = makeSavedQueryStore()
        let recent = makeRecentSearchStore()

        obsStore.save(sampleObservation())
        saved.save(SavedQuery(name: "q", adql: "SELECT 1"))

        let research = ResearchExporter(observationStore: obsStore, noteStore: noteStore)
        let search = SearchExporter(savedQueryStore: saved, recentSearchStore: recent)

        let service = ExportService()
        let tmpDir = makeTempDir()
        let bundleURL = await service.exportAll(to: tmpDir, modules: [research, search])
        guard let bundleURL else { return XCTFail("exportAll failed") }

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("research/observations.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("search/saved_queries.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("search/queries.md").path))
    }

    func testExportAllReadmeContainsModuleListing() async throws {
        let obsStore = makeObservationStore()
        let noteStore = makeNoteStore()
        obsStore.save(sampleObservation())

        let service = ExportService()
        let tmpDir = makeTempDir()
        let bundleURL = await service.exportAll(
            to: tmpDir,
            modules: [ResearchExporter(observationStore: obsStore, noteStore: noteStore)]
        )
        guard let bundleURL else { return XCTFail("exportAll failed") }

        let readme = try String(contentsOf: bundleURL.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("# Verbinal Export"))
        XCTAssertTrue(readme.contains("Research"))
        XCTAssertTrue(readme.contains("For Claude"))
        XCTAssertTrue(readme.contains("Suggested prompts"))
    }

    func testExportAllWithEmptyStoresStillProducesValidBundle() async throws {
        let obsStore = makeObservationStore()
        let noteStore = makeNoteStore()

        let service = ExportService()
        let tmpDir = makeTempDir()
        let bundleURL = await service.exportAll(
            to: tmpDir,
            modules: [ResearchExporter(observationStore: obsStore, noteStore: noteStore)]
        )
        guard let bundleURL else { return XCTFail("exportAll failed on empty stores") }

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        let markdown = try String(contentsOf: bundleURL.appendingPathComponent("research/notes.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("No notes have been written yet"))
    }

    // MARK: - ZIP helper

    #if os(macOS)
    func testZipFolderCreatesValidArchive() throws {
        let srcDir = makeTempDir()
        try "observation metadata".write(
            to: srcDir.appendingPathComponent("a.json"),
            atomically: true, encoding: .utf8
        )
        try "# notes".write(
            to: srcDir.appendingPathComponent("b.md"),
            atomically: true, encoding: .utf8
        )

        let zipURL = try ExportService.zipFolder(at: srcDir)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        XCTAssertTrue(zipURL.pathExtension == "zip")
        let attrs = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let size = attrs[.size] as? UInt64 ?? 0
        XCTAssertGreaterThan(size, 0, "Zip archive should be non-empty")
    }
    #endif

    // MARK: - Ticket 012: attached-file copy failures

    private struct StubModule: ExportableModule {
        let moduleID = "stub"
        let displayName = "Stub"
        var output: ExportModuleOutput
        func export(options: ExportOptions) async throws -> ExportModuleOutput { output }
    }

    func testExportFailsWhenAttachedFileMissing() async {
        var out = ExportModuleOutput()
        out.jsonFiles = ["data.json": Data("{}".utf8)]
        out.attachedFiles = [FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).fits")]
        let service = ExportService()
        var options = ExportOptions()
        options.includeFileCopies = true

        let url = await service.exportAll(to: makeTempDir(), modules: [StubModule(output: out)], options: options)

        XCTAssertNil(url, "export must fail when an attached file can't be copied")
        XCTAssertTrue(service.lastError?.contains("could not be copied") ?? false,
                      "expected a copy-failure error, got: \(service.lastError ?? "nil")")
    }

    func testExportCopiesAttachedFilesWhenPresent() async throws {
        let work = makeTempDir()
        let src = work.appendingPathComponent("real.fits")
        try Data("x".utf8).write(to: src)
        var out = ExportModuleOutput()
        out.jsonFiles = ["data.json": Data("{}".utf8)]
        out.attachedFiles = [src]
        let service = ExportService()
        var options = ExportOptions()
        options.includeFileCopies = true

        let bundleURL = await service.exportAll(to: makeTempDir(), modules: [StubModule(output: out)], options: options)
        guard let bundleURL else { return XCTFail("export failed: \(service.lastError ?? "nil")") }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("stub/files/real.fits").path),
            "the attached file should be copied into the bundle"
        )
    }
}
