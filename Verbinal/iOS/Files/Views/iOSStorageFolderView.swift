// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import SwiftUI
import UniformTypeIdentifiers

/// A folder of the person's storage: its folders, then its files newest
/// first; FITS files only unless they ask for all. Open picks from it; Your
/// Storage (plan 48 F2) manages it — the same list, with more actions.
struct iOSStorageFolderView: View {
    @Environment(AppState.self) private var appState

    let path: String
    let title: String
    var onOpen: (FileRef) -> Void
    /// Your Storage's actions; nil when the list is for picking.
    var manage: StorageActions?
    /// The quota, at the top of Your Storage.
    var quota: ResourceLoad?

    /// A deletion waiting for the person's answer; a folder's item count, when known.
    struct PendingDelete: Identifiable {
        let node: VOSpaceNode
        let items: Int?
        var id: String { node.path }
    }

    /// The folder's listing: loading, listed, or why not (plan 38).
    @State private var listing: Phase<[VOSpaceNode]> = .idle
    @State private var deleting: PendingDelete?
    @State private var naming = false
    @State private var newName = ""
    @State private var picking = false
    @State private var replacing: URL?
    @AppStorage("ios.open.fitsOnly") private var fitsOnly = true

    private var nodes: [VOSpaceNode] { listing.value ?? [] }

    private var folders: [VOSpaceNode] {
        nodes.filter(\.isContainer).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var files: [VOSpaceNode] {
        nodes.filter { !$0.isContainer && (!fitsOnly || $0.isFITS) }
            .sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
    }

    var body: some View {
        List {
            if let quota { quotaSection(quota) }
            if let problem = manage?.problem ?? listing.problem?.message {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            uploadsSection
            ForEach(folders) { folder in
                let link = NavigationLink {
                    iOSStorageFolderView(path: folder.path, title: folder.name, onOpen: onOpen, manage: manage)
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
                if manage != nil {
                    link.contextMenu { deleteButton(folder) }.swipeActions { swipeDelete(folder) }
                } else {
                    link
                }
            }
            ForEach(files) { node in
                let file = Self.fileRef(node)
                let row = Button { onOpen(file) } label: { fileRow(file) }
                if manage != nil {
                    row.contextMenu { fileMenu(file, node: node) }.swipeActions { swipeDelete(node) }
                } else {
                    row
                }
            }
            if case .ready = listing, folders.isEmpty, files.isEmpty {
                Text(fitsOnly ? "No FITS files here." : "Nothing here.").foregroundStyle(.secondary)
            }
        }
        .overlay { if listing.isLoadingFirst { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(deleting.map { FilesWording.storageDeleteTitle(name: $0.node.name) } ?? "",
                            isPresented: present($deleting), titleVisibility: .visible, presenting: deleting) { pending in
            Button(pending.node.isContainer ? "Delete Folder" : "Delete File", role: .destructive) {
                Task {
                    guard await manage?.delete(pending.node) == true else { return }
                    await load()
                }
            }
        } message: { pending in
            Text(FilesWording.storageDeleteMeaning(isFolder: pending.node.isContainer, items: pending.items))
        }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
                .disabled(!FilesRules.isValidName(newName))
        } message: {
            Text("In \(title)")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            if nodes.contains(where: { $0.name == url.lastPathComponent }) { replacing = url } else { upload(url) }
        }
        .confirmationDialog(replacing.map { String(localized: "Replace “\($0.lastPathComponent)”?") } ?? "",
                            isPresented: present($replacing), titleVisibility: .visible, presenting: replacing) { url in
            Button("Replace", role: .destructive) { upload(url) }
        } message: { _ in
            Text("A file with this name is already in this folder. This cannot be undone: storage has no trash.")
        }
    }

    static func fileRef(_ node: VOSpaceNode) -> FileRef {
        FileRef(place: .storage(path: node.path), name: node.name, size: node.sizeBytes, modified: node.lastModified)
    }

    // MARK: - Rows

    private func quotaSection(_ quota: ResourceLoad) -> some View {
        Section {
            Gauge(value: quota.used, in: 0...quota.total) {
                Text("\(Self.gigabytes(quota.used)) of \(Self.gigabytes(quota.total)) used")
            } currentValueLabel: {
                Text(verbatim: (quota.percent / 100).formatted(.percent.precision(.fractionLength(0))))
            }
            .tint(quota.percent > 90 ? .red : quota.percent > 70 ? .orange : .accentColor)
        }
    }

    static func gigabytes(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)))) GB"
    }

    /// Transfers into this folder, under way.
    @ViewBuilder
    private var uploadsSection: some View {
        let here = (manage?.uploads ?? [:]).filter { ($0.key as NSString).deletingLastPathComponent == path }
        if !here.isEmpty {
            Section("Uploading") {
                ForEach(here.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: (key as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        ProgressView(value: here[key] ?? 0)
                    }
                }
            }
        }
    }

    /// A file, and in Your Storage whether this device has it.
    private func fileRow(_ file: FileRef) -> some View {
        HStack {
            iOSFileRow(file: file)
            Spacer(minLength: 8)
            if let manage, case .storage(let path) = file.place {
                if let fraction = manage.downloads[path] {
                    ProgressView(value: fraction).frame(width: 44)
                } else if let local = manage.library.files.first(where: { $0.origin?.storagePath == path }) {
                    Image(systemName: local.kind.icon)
                        .foregroundStyle(local.kind.tint)
                        .accessibilityLabel(Text(local.kind.title))
                }
            }
        }
    }

    @ViewBuilder
    private func fileMenu(_ file: FileRef, node: VOSpaceNode) -> some View {
        Button { onOpen(file) } label: { Label("Open", systemImage: "eye") }
        if let manage {
            Button { Task { await manage.download(file, keep: false) } } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            Button { Task { await manage.download(file, keep: true) } } label: {
                Label("Keep on This Device", systemImage: "pin")
            }
        }
        Divider()
        deleteButton(node)
    }

    private func deleteButton(_ node: VOSpaceNode) -> some View {
        Button(role: .destructive) { askToDelete(node) } label: { Label("Delete…", systemImage: "trash") }
    }

    /// Not the destructive role: that slides the row away before the person answers.
    private func swipeDelete(_ node: VOSpaceNode) -> some View {
        Button { askToDelete(node) } label: { Label("Delete…", systemImage: "trash") }
            .tint(.red)
    }

    /// Storage has no trash: every deletion asks, and a folder's says what it holds.
    private func askToDelete(_ node: VOSpaceNode) {
        Task {
            let items = node.isContainer ? await manage?.count(in: node.path) : nil
            deleting = PendingDelete(node: node, items: items)
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some SwiftUI.ToolbarContent {
        if manage != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newName = ""; naming = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { picking = true } label: { Label("Upload from This Device…", systemImage: "square.and.arrow.up") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle("FITS Files Only", isOn: $fitsOnly)
            } label: {
                Label("Show", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }

    // MARK: - Work

    private func load() async {
        let attempt = listing.begin()
        let storage = manage?.storage ?? VOSpaceBrowserService(network: appState.network, endpoints: appState.endpoints)
        do {
            listing.finish(attempt, with: .success(try await storage.listNodes(username: appState.username, path: path)))
        } catch {
            listing.finish(attempt, with: .failure(error))
        }
    }

    private func createFolder() {
        let name = newName
        Task { if await manage?.createFolder(name, in: path) == true { await load() } }
    }

    private func upload(_ url: URL) {
        Task { if await manage?.upload(url, to: path) == true { await load() } }
    }

    /// Shown while `item` has a value; dismissing clears it.
    private func present<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// The person's CANFAR storage, managed (plan 48 F2): Home with its quota
/// at the top — or one folder, for Show in Storage — with Your Storage's actions.
struct iOSYourStorageView: View {
    @Environment(AppState.self) private var appState

    var path = ""
    /// The quota's numbers; Home shows them.
    var storage: StorageModel?
    var library: DeviceLibrary
    var onOpen: (FileRef) -> Void

    @State private var actions: StorageActions?

    private var quota: ResourceLoad? {
        guard let storage, storage.hasData else { return nil }
        return ResourceLoad(used: storage.usedGB, total: storage.quotaGB)
    }

    var body: some View {
        Group {
            if let actions {
                iOSStorageFolderView(path: path,
                                     title: path.isEmpty ? String(localized: "Your Storage") : (path as NSString).lastPathComponent,
                                     onOpen: onOpen, manage: actions, quota: quota)
            } else {
                ProgressView()
            }
        }
        .task {
            if actions == nil {
                actions = StorageActions(
                    storage: VOSpaceBrowserService(network: appState.network, endpoints: appState.endpoints),
                    username: appState.username, library: library)
            }
            await library.reload()
            if let storage { await storage.loadQuota(username: appState.username) }
        }
    }
}
