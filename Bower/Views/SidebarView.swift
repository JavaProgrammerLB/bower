import SwiftUI

private struct SidebarRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder(Folder)
        case source(SourceRef, parent: String?)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .folder(let folder): "folder:\(folder.id)"
        case .source(let ref, _): "\(ref.type.rawValue):\(ref.id)"
        }
    }

    var selection: LibrarySelection {
        switch kind {
        case .folder(let folder): .folder(folder.id)
        case .source(let ref, _): LibrarySelection(ref)
        }
    }
}

private enum PendingDeletion: Identifiable {
    case source(SourceRef, title: String)
    case folder(Folder)

    var id: String {
        switch self {
        case .source(let ref, _): "source:\(ref.id)"
        case .folder(let folder): "folder:\(folder.id)"
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @State private var pendingDeletion: PendingDeletion?
    @State private var renamingFolder: Folder?
    @State private var folderName = ""

    private var store: LibraryStore { app.store }

    var body: some View {
        @Bindable var app = app
        let rows = buildRows()

        List(selection: $app.selection) {
            Section {
                Label("Latest", systemImage: "sparkles.tv")
                    .tag(LibrarySelection.latest)
                Label("Bookmarks", systemImage: "bookmark")
                    .badge(store.bookmarks.count)
                    .tag(LibrarySelection.bookmarks)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(LibrarySelection.history)
            }

            Section("Library") {
                ForEach(rows) { row in
                    rowView(row)
                        .tag(row.selection)
                }
                .onMove { from, to in move(rows: rows, from: from, to: to) }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Folder") { startNewFolder() }
            Button("Add Playlist, Channel, or Video…") { app.activeSheet = .add }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            RefreshStatusBar()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    app.activeSheet = .add
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add Playlist, Channel, or Video (⌘N)")
            }
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                            presenting: pendingDeletion) { deletion in
            switch deletion {
            case .source(let ref, _):
                Button("Delete", role: .destructive) { app.deleteSource(ref) }
            case .folder(let folder):
                Button("Delete Folder Only") { store.removeFolder(folder.id, deletingContents: false) }
                Button("Delete Folder and Contents", role: .destructive) { store.removeFolder(folder.id, deletingContents: true) }
            }
        } message: { deletion in
            switch deletion {
            case .source:
                Text("Its saved videos are removed from your library.")
            case .folder:
                Text("You can keep the playlists and channels inside it, or delete them along with the folder.")
            }
        }
        .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = folderName.trimmingCharacters(in: .whitespaces)
                if let folder = renamingFolder, !name.isEmpty { store.renameFolder(folder.id, to: name) }
            }
        }
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .source(_, let title): "Delete “\(title)”?"
        case .folder(let folder): "Delete the folder “\(folder.name)”?"
        case nil: ""
        }
    }

    // MARK: Rows

    private func buildRows() -> [SidebarRow] {
        var rows: [SidebarRow] = []
        for entry in store.sidebarOrder {
            switch entry {
            case .source(let ref):
                if store.source(ref) != nil { rows.append(SidebarRow(kind: .source(ref, parent: nil))) }
            case .folder(let id, let children):
                guard let folder = store.folder(id) else { continue }
                rows.append(SidebarRow(kind: .folder(folder)))
                if !folder.isCollapsed {
                    for child in children where store.source(child) != nil {
                        rows.append(SidebarRow(kind: .source(child, parent: id)))
                    }
                }
            }
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: SidebarRow) -> some View {
        switch row.kind {
        case .folder(let folder):
            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        store.setFolderCollapsed(folder.id, !folder.isCollapsed)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(folder.isCollapsed ? 0 : 90))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Label(folder.name, systemImage: folder.isCollapsed ? "folder" : "folder.fill")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contextMenu {
                Button(folder.isCollapsed ? "Expand" : "Collapse") { store.setFolderCollapsed(folder.id, !folder.isCollapsed) }
                Button("Rename…") {
                    folderName = folder.name
                    renamingFolder = folder
                }
                Divider()
                Button("New Folder") { startNewFolder() }
                Divider()
                Button("Delete Folder…", role: .destructive) { pendingDeletion = .folder(folder) }
            }

        case .source(let ref, let parent):
            if let source = store.source(ref) {
                SourceLabel(source: source, kind: ref.type, isRefreshing: app.library.refreshingRefs.contains(ref))
                    .padding(.leading, parent == nil ? 0 : 18)
                    .contextMenu { sourceMenu(ref: ref, title: source.title, parent: parent) }
            }
        }
    }

    @ViewBuilder
    private func sourceMenu(ref: SourceRef, title: String, parent: String?) -> some View {
        Button("Check for New Videos") { app.library.refresh(ref) }
            .disabled(app.library.isRefreshing)
        Button("Reload All Videos") { app.library.refresh(ref, full: true) }
            .disabled(app.library.isRefreshing)
        Divider()
        Menu("Move to Folder") {
            ForEach(store.folders.filter { $0.id != parent }) { folder in
                Button(folder.name) { store.move(ref, toFolder: folder.id) }
            }
            if !store.folders.isEmpty { Divider() }
            Button("New Folder…") {
                let folder = store.createFolder(named: "New Folder")
                store.move(ref, toFolder: folder.id)
                folderName = folder.name
                renamingFolder = folder
            }
        }
        if parent != nil {
            Button("Move to Top Level") { store.move(ref, toFolder: nil) }
        }
        Divider()
        Button("Open in YouTube") { NSWorkspace.shared.open(Source.browserURL(kind: ref.type, id: ref.id)) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Source.browserURL(kind: ref.type, id: ref.id).absoluteString, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDeletion = .source(ref, title: title) }
    }

    private func startNewFolder() {
        let folder = store.createFolder(named: "New Folder")
        folderName = folder.name
        renamingFolder = folder
    }

    // MARK: Reordering

    /// Applies a drag in the flattened sidebar to the nested order. A source
    /// lands in the folder of the row it is dropped under (an expanded folder
    /// header counts as its first slot); folders move only between top-level
    /// entries.
    private func move(rows: [SidebarRow], from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        var order = store.sidebarOrder

        switch rows[from].kind {
        case .folder(let folder):
            guard let index = order.firstIndex(where: { if case .folder(folder.id, _) = $0 { true } else { false } }) else { return }
            let entry = order.remove(at: index)
            var insertAt = order.count
            for row in rows[min(destination, rows.count)...] {
                switch row.kind {
                case .folder(let other) where other.id == folder.id: continue
                case .source(_, let parent) where parent == folder.id: continue
                case .folder(let other):
                    insertAt = order.firstIndex { if case .folder(other.id, _) = $0 { true } else { false } } ?? insertAt
                case .source(let ref, let parent):
                    if let parent {
                        insertAt = order.firstIndex { if case .folder(parent, _) = $0 { true } else { false } } ?? insertAt
                    } else {
                        insertAt = order.firstIndex(of: .source(ref)) ?? insertAt
                    }
                }
                break
            }
            order.insert(entry, at: insertAt)

        case .source(let ref, _):
            order = order.compactMap { entry in
                switch entry {
                case .source(let r): r == ref ? nil : entry
                case .folder(let id, let children): .folder(id: id, children: children.filter { $0 != ref })
                }
            }
            var anchor = destination - 1
            if anchor == from { anchor -= 1 }

            func insertInFolder(_ folderID: String, after child: SourceRef?) {
                guard let index = order.firstIndex(where: { if case .folder(folderID, _) = $0 { true } else { false } }),
                      case .folder(_, var children) = order[index] else { return }
                let position = child.flatMap { c in children.firstIndex(of: c).map { $0 + 1 } } ?? 0
                children.insert(ref, at: position)
                order[index] = .folder(id: folderID, children: children)
            }

            if anchor < 0 {
                order.insert(.source(ref), at: 0)
            } else {
                switch rows[anchor].kind {
                case .folder(let folder) where !folder.isCollapsed:
                    insertInFolder(folder.id, after: nil)
                case .folder(let folder):
                    let index = order.firstIndex { if case .folder(folder.id, _) = $0 { true } else { false } } ?? order.count - 1
                    order.insert(.source(ref), at: index + 1)
                case .source(let other, let parent?):
                    insertInFolder(parent, after: other)
                case .source(let other, nil):
                    let index = order.firstIndex(of: .source(other)) ?? order.count - 1
                    order.insert(.source(ref), at: index + 1)
                }
            }
        }

        store.replaceSidebarOrder(order)
    }
}

private struct SourceLabel: View {
    let source: Source
    let kind: SourceKind
    let isRefreshing: Bool

    var body: some View {
        Label {
            HStack {
                Text(source.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                }
            }
        } icon: {
            RemoteImage(url: source.thumbnail) {
                Image(systemName: kind == .channel ? "person.crop.circle.fill" : "list.and.film")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 18, height: 18)
            .clipShape(kind == .channel ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
        }
        .help(source.title)
    }
}

private struct RefreshStatusBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let library = app.library
        HStack(spacing: 8) {
            if library.isRefreshing {
                ProgressView(value: Double(library.completed), total: Double(max(library.total, 1)))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                Text("\(library.completed)/\(library.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    library.refreshAll(full: NSEvent.modifierFlags.contains(.option))
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check for New Videos (⌘R) — Option-click to reload everything")
                .disabled(app.store.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusText: String {
        guard let last = app.store.lastRefresh else { return "Not updated yet" }
        if Date().timeIntervalSince(last) < 60 { return "Updated just now" }
        return "Updated \(RelativeTime.format(last))"
    }
}
