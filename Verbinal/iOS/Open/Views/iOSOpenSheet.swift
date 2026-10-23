// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import UniformTypeIdentifiers

/// Where a file to review comes from (plan 47 phase 3): what was opened
/// lately, the person's CANFAR storage (read where it is), or a file on this
/// device — the same sheet from FITS and Cube.
struct iOSOpenSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var recents: iOSRecentFiles
    var onOpen: (FileRef) -> Void

    @State private var showImporter = false
    @State private var importProblem: String?

    var body: some View {
        NavigationStack {
            List {
                if !recents.items.isEmpty {
                    Section("Recent") {
                        ForEach(recents.items.prefix(8)) { file in
                            Button { open(file) } label: { iOSFileRow(file: file) }
                                .swipeActions {
                                    Button("Remove", role: .destructive) { recents.remove(file) }
                                }
                        }
                    }
                }

                Section {
                    if appState.isAuthenticated {
                        NavigationLink {
                            iOSStorageFolderView(path: "", title: String(localized: "Home"), onOpen: open)
                        } label: {
                            Label("Home", systemImage: "house")
                        }
                    } else {
                        Label("Sign in to open files from your storage.", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Your Storage")
                } footer: {
                    Text("Read where it is: its headers first, the file itself only when you ask.")
                }

                Section("On This Device") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Files…", systemImage: "folder")
                    }
                    if let importProblem {
                        Text(importProblem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Open")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.fits, .data]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard FileHelper.isFITS(url.pathExtension) || url.pathExtension.lowercased() == "fz",
                          let file = FileRef.device(url) else {
                        importProblem = String(localized: "\(url.lastPathComponent) is not a FITS file.")
                        return
                    }
                    open(file)
                case .failure(let error):
                    importProblem = error.localizedDescription
                }
            }
        }
        .iosSheetChrome()
    }

    private func open(_ file: FileRef) {
        recents.add(file)
        onOpen(file)
        dismiss()
    }
}

/// A folder of the person's storage: its folders, then its files newest
/// first; FITS files only unless they ask for all.
struct iOSStorageFolderView: View {
    @Environment(AppState.self) private var appState

    let path: String
    let title: String
    var onOpen: (FileRef) -> Void

    @State private var nodes: [VOSpaceNode] = []
    @State private var isLoading = false
    @State private var problem: String?
    @AppStorage("ios.open.fitsOnly") private var fitsOnly = true

    private var folders: [VOSpaceNode] {
        nodes.filter(\.isContainer).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var files: [VOSpaceNode] {
        nodes.filter { !$0.isContainer && (!fitsOnly || $0.isFITS) }
            .sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
    }

    var body: some View {
        List {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            ForEach(folders) { folder in
                NavigationLink {
                    iOSStorageFolderView(path: folder.path, title: folder.name, onOpen: onOpen)
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
            }
            ForEach(files) { node in
                Button {
                    onOpen(FileRef(place: .storage(path: node.path), name: node.name,
                                   size: node.sizeBytes, modified: node.lastModified))
                } label: {
                    iOSFileRow(file: FileRef(place: .storage(path: node.path), name: node.name,
                                             size: node.sizeBytes, modified: node.lastModified))
                }
            }
            if !isLoading && problem == nil && folders.isEmpty && files.isEmpty {
                Text(fitsOnly ? "No FITS files here." : "Nothing here.").foregroundStyle(.secondary)
            }
        }
        .overlay { if isLoading && nodes.isEmpty { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("FITS Files Only", isOn: $fitsOnly)
                } label: {
                    Label("Show", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let storage = VOSpaceBrowserService(network: appState.network, endpoints: appState.endpoints)
            nodes = try await storage.listNodes(username: appState.username, path: path)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A file as Open lists it: its name, size and date, and where it is.
struct iOSFileRow: View {
    let file: FileRef

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.isRemote ? "icloud" : "iphone")
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let size = file.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let modified = file.modified {
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }
}

extension UTType {
    /// FITS, as Verbinal declares it for iOS (Info-iOS.plist).
    static let fits = UTType(importedAs: "gov.nasa.gsfc.fits", conformingTo: .data)
}
