// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import UniformTypeIdentifiers

/// Where a file to review comes from (plan 47 phase 3): what was opened
/// lately, the person's CANFAR storage (read where it is), or a file on this
/// device — the same sheet from FITS and Cube. Signed out (plan 49), storage
/// asks to sign in; files on the device open as ever.
struct iOSOpenSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var recents: iOSRecentFiles
    /// This device's files: a storage file here opens signed out.
    var files: DeviceFiles
    /// The shell closes this sheet, then shows the sign-in sheet.
    var onSignIn: () -> Void
    var onOpen: (FileRef) -> Void

    @State private var showImporter = false
    @State private var importProblem: String?

    var body: some View {
        NavigationStack {
            List {
                if !recents.items.isEmpty {
                    Section("Recent") {
                        ForEach(recents.items.prefix(8)) { file in
                            let locked = file.isRemote && !appState.isAuthenticated && !files.has(file)
                            Button { locked ? onSignIn() : open(file) } label: {
                                HStack {
                                    iOSFileRow(file: file).opacity(locked ? 0.5 : 1)
                                    if locked {
                                        Spacer()
                                        Image(systemName: "lock.fill").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityHint(locked ? Text("In your storage: sign in to open it") : Text(verbatim: ""))
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
                        Button { onSignIn() } label: {
                            Label("Sign In to Open Files from Your Storage", systemImage: "lock")
                        }
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

                // Two small public files to try the viewers with (plan 49 D4).
                Section {
                    ForEach(iOSSample.all) { sample in
                        Button { openSample(sample) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sample.title)
                                    Text(verbatim: sample.credit).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: sample.systemImage)
                            }
                        }
                    }
                } header: {
                    Text("Samples")
                } footer: {
                    Text("Public data, cut down for Verbinal. Each file's header credits the observation.")
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

    /// A sample opens from the app's bundle, and stays out of Recent: it is
    /// always here.
    private func openSample(_ sample: iOSSample) {
        guard let url = sample.url, let file = FileRef.device(url) else { return }
        onOpen(file)
        dismiss()
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
