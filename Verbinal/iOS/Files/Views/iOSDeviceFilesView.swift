// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI

/// The files Verbinal holds on this device (plan 48), as iPhone Storage
/// shows an app's: what there is, its size, and what can go. A tap opens a
/// file; a swipe deletes it; Edit deletes several, after one question.
struct iOSDeviceFilesView: View {
    @Environment(AppState.self) private var appState
    var library: DeviceLibrary
    /// Opens a file in FITS or Cube, through the shell.
    var onOpen: (FileRef) -> Void
    /// Closes the viewers showing these files, before they go.
    var onClose: ([URL]) -> Void
    /// Only the files not opened lately: the suggestion's review.
    var staleOnly = false

    enum Order: String, CaseIterable, Identifiable {
        case date, size, name
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .date: return "Last Opened"
            case .size: return "Size"
            case .name: return "Name"
            }
        }
    }

    @AppStorage("ios.files.order") private var order: Order = .date
    @State private var query = ""
    @State private var selection: Set<URL> = []
    @State private var editMode: EditMode = .inactive
    @State private var confirming: [LocalFile] = []
    @State private var confirmingClear = false
    /// The storage folder Show in Storage opens.
    @State private var storageFolder: String?

    static var deviceTitle: LocalizedStringKey {
        UIDevice.current.userInterfaceIdiom == .pad ? "On This iPad" : "On This iPhone"
    }

    static var deviceIcon: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    private var shown: [LocalFile] {
        let base = staleOnly ? library.stale : library.files
        let found = query.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch order {
        case .date: return found.sorted { $0.lastOpened > $1.lastOpened }
        case .size: return found.sorted { $0.size > $1.size }
        case .name: return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        List(selection: $selection) {
            if !staleOnly && query.isEmpty && !library.files.isEmpty {
                usage
                if !library.stale.isEmpty { suggestion }
            }
            if let problem = library.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(LocalFileKind.allCases) { kind in
                let files = shown.filter { $0.kind == kind }
                if !files.isEmpty {
                    Section {
                        ForEach(files) { row($0) }
                    } header: {
                        Text(kind.title)
                    } footer: {
                        Text(kind.footer(capGB: library.capGB))
                    }
                }
            }
        }
        .overlay {
            if shown.isEmpty { emptyState }
        }
        .navigationTitle(staleOnly ? Text("Not Opened in \(FilesRules.staleDays) Days") : Text(Self.deviceTitle))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("File name"))
        .toolbar { toolbar }
        .environment(\.editMode, $editMode)
        .confirmationDialog(FilesWording.deleteTitle(confirming), isPresented: confirmingShown, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(confirming) }
        } message: {
            Text(FilesWording.deleteMeaning(confirming))
        }
        .confirmationDialog(FilesWording.clearDownloadsTitle(library.bytes(.downloads)), isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Delete All Downloads", role: .destructive) {
                Task { await library.clearDownloads(closing: onClose) }
            }
        } message: {
            Text(FilesWording.clearDownloadsMeaning)
        }
        .navigationDestination(item: $storageFolder) { folder in
            iOSYourStorageView(path: folder, library: library, onOpen: onOpen)
        }
        .task { await library.reload() }
        .refreshable { await library.reload() }
    }

    // MARK: - What Verbinal uses

    private var usage: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Verbinal uses \(FilesWording.bytes(library.bytes()))").font(.headline)
                iOSUsageBar(parts: LocalFileKind.allCases.map { ($0.tint, library.bytes($0)) })
                    .frame(height: 10)
                    .accessibilityHidden(true)
                HStack(spacing: 14) {
                    ForEach(LocalFileKind.allCases.filter { library.bytes($0) > 0 }) { kind in
                        Label {
                            Text(verbatim: "\(String(localized: kind.title)) \(FilesWording.bytes(library.bytes(kind)))")
                        } icon: {
                            Circle().fill(kind.tint).frame(width: 8, height: 8)
                        }
                    }
                }
                .font(.caption)
                if let available = library.available {
                    Text("\(FilesWording.bytes(available)) free on this device")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            if !library.files(.downloads).isEmpty {
                Button("Clear Downloads…", role: .destructive) { confirmingClear = true }
            }
        }
    }

    /// Not opened in a while: a suggestion, as iPhone Storage makes them.
    /// Nothing goes without the person.
    private var suggestion: some View {
        let stale = library.stale
        return Section {
            NavigationLink {
                iOSDeviceFilesView(library: library, onOpen: onOpen, onClose: onClose, staleOnly: true)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not opened in \(FilesRules.staleDays) days")
                    Text(verbatim: "\(FilesWording.files(stale.count)), \(FilesWording.bytes(FilesRules.bytes(stale)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Review them, and delete what you no longer need.")
        }
    }

    // MARK: - A file

    private func row(_ file: LocalFile) -> some View {
        Button { open(file) } label: { iOSLocalFileRow(file: file) }
            .tag(file.url)
            .swipeActions {
                Button("Delete", role: .destructive) { delete([file]) }
            }
            .contextMenu {
                Button { open(file) } label: { Label("Open", systemImage: "eye") }
                ShareLink(item: iOSFileShare(url: file.url), preview: iOSFileShare.preview(file.url)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if file.kind != .kept {
                    Button { Task { await library.keep(file) } } label: { Label("Keep on This Device", systemImage: "pin") }
                } else if file.isInStorage {
                    Button { Task { await library.unkeep(file) } } label: { Label("Don't Keep", systemImage: "pin.slash") }
                }
                if let path = file.origin?.storagePath, appState.isAuthenticated {
                    Button { storageFolder = (path as NSString).deletingLastPathComponent } label: {
                        Label("Show in Storage", systemImage: "externaldrive")
                    }
                }
                Divider()
                Button(role: .destructive) { confirming = [file] } label: { Label("Delete…", systemImage: "trash") }
            }
    }

    private func open(_ file: LocalFile) {
        guard !editMode.isEditing, let ref = file.fileRef else { return }
        onOpen(ref)
    }

    private func delete(_ files: [LocalFile]) {
        selection.subtract(files.map(\.url))
        if files.count > 1 { editMode = .inactive }
        Task { await library.delete(files, closing: onClose) }
    }

    private var confirmingShown: Binding<Bool> {
        Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } })
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some SwiftUI.ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort By", selection: $order) {
                    ForEach(Order.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !shown.isEmpty { EditButton() }
        }
        if editMode.isEditing {
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    confirming = shown.filter { selection.contains($0.url) }
                } label: {
                    Text("Delete (\(selection.count))")
                }
                .disabled(selection.isEmpty)
            }
        } else if staleOnly && !shown.isEmpty {
            ToolbarItem(placement: .bottomBar) {
                Button("Delete All…", role: .destructive) { confirming = shown }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if staleOnly {
            ContentUnavailableView("Nothing to Review", systemImage: "checkmark.circle",
                                   description: Text("Every file here was opened in the last \(FilesRules.staleDays) days."))
        } else {
            ContentUnavailableView("No Files on This Device", systemImage: Self.deviceIcon,
                                   description: Text("Files you download from your storage, keep, or receive from other apps appear here."))
        }
    }
}

/// A file as On This iPhone lists it: its name, size, where it came from,
/// and when it was last opened.
struct iOSLocalFileRow: View {
    let file: LocalFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.kind.icon)
                .foregroundStyle(file.kind.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [FilesWording.bytes(file.size)]
        if let folder = file.storageFolder { parts.append(String(localized: "from \(folder)")) }
        let when = file.lastOpened.formatted(.relative(presentation: .named))
        parts.append(file.origin?.opened != nil ? String(localized: "opened \(when)") : String(localized: "added \(when)"))
        return parts.joined(separator: " · ")
    }
}

/// What Verbinal uses, by kind, in one bar.
struct iOSUsageBar: View {
    let parts: [(color: Color, bytes: Int64)]

    var body: some View {
        GeometryReader { geometry in
            let total = max(parts.reduce(0) { $0 + $1.bytes }, 1)
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.bytes > 0 {
                        part.color.frame(width: max(geometry.size.width * CGFloat(part.bytes) / CGFloat(total) - 2, 3))
                    }
                }
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
            .background(Color.secondary.opacity(0.15), in: Capsule())
        }
    }
}

extension LocalFileKind {
    var title: LocalizedStringResource {
        switch self {
        case .kept: return "Kept"
        case .downloads: return "Downloads"
        case .received: return "From Other Apps"
        }
    }

    /// What a kind is, and what deleting one of it means.
    func footer(capGB: Int) -> LocalizedStringKey {
        switch self {
        case .kept:
            return "Kept until you delete them. They show in the Files app, in Verbinal's folder, and are left out of iCloud backup."
        case .downloads:
            return "Copies of files in your storage, up to \(capGB) GB; the least recently opened go first. iOS may also remove them when it needs space."
        case .received:
            return "Files other apps sent to Verbinal, such as Mail or AirDrop. Deleting one removes Verbinal's copy only."
        }
    }

    var icon: String {
        switch self {
        case .kept: return "pin.fill"
        case .downloads: return "arrow.down.circle"
        case .received: return "tray.and.arrow.down"
        }
    }

    var tint: Color {
        switch self {
        case .kept: return .accentColor
        case .downloads: return .teal
        case .received: return .orange
        }
    }
}
