import Foundation
import Observation

nonisolated struct LibraryFile: Codable, Sendable {
    var playlists: [Source] = []
    var channels: [Source] = []
    var folders: [Folder] = []
    var sidebarOrder: [SidebarEntry] = []
}

nonisolated struct UserFile: Codable, Sendable {
    var bookmarks: [Bookmark] = []
    var watchHistory: [HistoryEntry] = []
    var skippedVideos: [String] = []
    var lastRefresh: Double?
}

/// The user's library: sources, folders and the sidebar order, plus the
/// lighter per-video state (bookmarks, history, hidden videos).
@Observable
final class LibraryStore {
    private static let videoListLimit = 100

    private(set) var playlists: [Source] = []
    private(set) var channels: [Source] = []
    private(set) var folders: [Folder] = []
    private(set) var sidebarOrder: [SidebarEntry] = []

    private(set) var bookmarks: [String: Bookmark] = [:]
    private(set) var watchHistory: [HistoryEntry] = []
    private(set) var skipped: Set<String> = []
    var lastRefresh: Date? {
        didSet { scheduleUserSave(changedVideos: false) }
    }

    /// Bumped whenever any source's videos or a folder's members change, so
    /// derived lists (Latest, folders) know to rebuild without diffing
    /// thousands of videos. Renaming or collapsing a folder leaves it alone.
    private(set) var contentRevision = 0
    /// Bumped when bookmarks, history or hidden videos change.
    private(set) var userRevision = 0

    @ObservationIgnored private var librarySaveTask: Task<Void, Never>?
    @ObservationIgnored private var userSaveTask: Task<Void, Never>?

    init() {
        if let file = JSONFile.read(LibraryFile.self, from: AppPaths.library) {
            playlists = file.playlists
            channels = file.channels
            folders = file.folders
            sidebarOrder = file.sidebarOrder
            // Only with a library to compare against: pruning against an
            // empty one would delete every avatar.
            AvatarCache.prune(keeping: channels.compactMap(\.thumbnail))
        }
        if let user = JSONFile.read(UserFile.self, from: AppPaths.userData) {
            bookmarks = Dictionary(user.bookmarks.map { ($0.videoID, $0) }, uniquingKeysWith: { a, _ in a })
            watchHistory = Array(user.watchHistory.prefix(Self.videoListLimit))
            skipped = Set(user.skippedVideos)
            lastRefresh = user.lastRefresh.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        if reconcileSidebarOrder() { scheduleLibrarySave() }
    }

    // MARK: Persistence

    private func scheduleLibrarySave(contentChanged: Bool = true) {
        if contentChanged { contentRevision += 1 }
        librarySaveTask?.cancel()
        let snapshot = LibraryFile(playlists: playlists, channels: channels, folders: folders, sidebarOrder: sidebarOrder)
        librarySaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: AppPaths.library)
        }
    }

    private func scheduleUserSave(changedVideos: Bool = true) {
        if changedVideos { userRevision += 1 }
        userSaveTask?.cancel()
        let snapshot = UserFile(
            bookmarks: Array(bookmarks.values),
            watchHistory: watchHistory,
            skippedVideos: Array(skipped),
            lastRefresh: lastRefresh.map { $0.timeIntervalSince1970 * 1000 }
        )
        userSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: AppPaths.userData)
        }
    }

    @concurrent
    private static func write<T: Encodable & Sendable>(_ value: T, to url: URL) async {
        JSONFile.write(value, to: url)
    }

    /// Writes pending changes immediately; called when the app quits.
    func flush() {
        if librarySaveTask != nil {
            librarySaveTask?.cancel()
            JSONFile.write(LibraryFile(playlists: playlists, channels: channels, folders: folders, sidebarOrder: sidebarOrder), to: AppPaths.library)
        }
        if userSaveTask != nil {
            userSaveTask?.cancel()
            JSONFile.write(UserFile(bookmarks: Array(bookmarks.values), watchHistory: watchHistory,
                                    skippedVideos: Array(skipped),
                                    lastRefresh: lastRefresh.map { $0.timeIntervalSince1970 * 1000 }), to: AppPaths.userData)
        }
    }

    // MARK: Sources

    func sources(_ kind: SourceKind) -> [Source] {
        kind == .playlist ? playlists : channels
    }

    func source(_ ref: SourceRef) -> Source? {
        sources(ref.type).first { $0.id == ref.id }
    }

    func folder(_ id: String) -> Folder? {
        folders.first { $0.id == id }
    }

    var isEmpty: Bool { playlists.isEmpty && channels.isEmpty }

    /// Inserts or replaces a source. New sources go above the first folder,
    /// where they are easiest to spot.
    func upsert(_ source: Source, kind: SourceKind) {
        var list = sources(kind)
        if let index = list.firstIndex(where: { $0.id == source.id }) {
            list[index] = source
        } else {
            list.append(source)
            insertAtTop([.source(SourceRef(type: kind, id: source.id))])
        }
        if kind == .playlist { playlists = list } else { channels = list }
        scheduleLibrarySave()
    }

    /// Drops one video from every playlist and channel holding it.
    func removeVideo(_ videoID: String) {
        func strip(_ list: inout [Source]) -> Bool {
            var changed = false
            for index in list.indices where list[index].items.contains(where: { $0.id == videoID }) {
                list[index].items.removeAll { $0.id == videoID }
                changed = true
            }
            return changed
        }
        let changedPlaylists = strip(&playlists)
        let changedChannels = strip(&channels)
        if changedPlaylists || changedChannels { scheduleLibrarySave() }
    }

    func remove(_ ref: SourceRef) {
        if ref.type == .playlist { playlists.removeAll { $0.id == ref.id } } else { channels.removeAll { $0.id == ref.id } }
        removeFromOrder(ref)
        scheduleLibrarySave()
    }

    // MARK: Folders & ordering

    @discardableResult
    func createFolder(named name: String) -> Folder {
        let folder = Folder(id: UUID().uuidString.lowercased(), name: name, isCollapsed: false)
        folders.append(folder)
        sidebarOrder.append(.folder(id: folder.id, children: []))
        scheduleLibrarySave(contentChanged: false)
        return folder
    }

    func renameFolder(_ id: String, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
        scheduleLibrarySave(contentChanged: false)
    }

    func setFolderCollapsed(_ id: String, _ collapsed: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isCollapsed = collapsed
        scheduleLibrarySave(contentChanged: false)
    }

    /// Deletes a folder. Its playlists and channels are either deleted with it
    /// or moved back to the top level.
    func removeFolder(_ id: String, deletingContents: Bool) {
        guard let index = sidebarOrder.firstIndex(where: { if case .folder(id, _) = $0 { true } else { false } }),
              case .folder(_, let children) = sidebarOrder[index]
        else { return }

        sidebarOrder.remove(at: index)
        if deletingContents {
            let playlistIDs = Set(children.filter { $0.type == .playlist }.map(\.id))
            let channelIDs = Set(children.filter { $0.type == .channel }.map(\.id))
            playlists.removeAll { playlistIDs.contains($0.id) }
            channels.removeAll { channelIDs.contains($0.id) }
        } else {
            insertAtTop(children.map { .source($0) })
        }
        folders.removeAll { $0.id == id }
        scheduleLibrarySave()
    }

    func folderID(containing ref: SourceRef) -> String? {
        for entry in sidebarOrder {
            if case .folder(let id, let children) = entry, children.contains(ref) { return id }
        }
        return nil
    }

    func folderChildren(_ id: String) -> [SourceRef] {
        for entry in sidebarOrder {
            if case .folder(id, let children) = entry { return children }
        }
        return []
    }

    func move(_ ref: SourceRef, toFolder folderID: String?) {
        removeFromOrder(ref)
        if let folderID, let index = sidebarOrder.firstIndex(where: { if case .folder(folderID, _) = $0 { true } else { false } }),
           case .folder(_, var children) = sidebarOrder[index] {
            children.append(ref)
            sidebarOrder[index] = .folder(id: folderID, children: children)
        } else {
            insertAtTop([.source(ref)])
        }
        scheduleLibrarySave()
    }

    func replaceSidebarOrder(_ order: [SidebarEntry]) {
        guard order != sidebarOrder else { return }
        sidebarOrder = order
        scheduleLibrarySave()
    }

    private func insertAtTop(_ entries: [SidebarEntry]) {
        guard !entries.isEmpty else { return }
        if let firstFolder = sidebarOrder.firstIndex(where: \.isFolder) {
            sidebarOrder.insert(contentsOf: entries, at: firstFolder)
        } else {
            sidebarOrder.append(contentsOf: entries)
        }
    }

    private func removeFromOrder(_ ref: SourceRef) {
        sidebarOrder = sidebarOrder.compactMap { entry in
            switch entry {
            case .source(let r): return r == ref ? nil : entry
            case .folder(let id, let children): return .folder(id: id, children: children.filter { $0 != ref })
            }
        }
    }

    /// Makes `sidebarOrder` agree with what exists: drops entries for deleted
    /// sources and folders (promoting a lost folder's children), and lists
    /// sources or folders that no entry mentions.
    @discardableResult
    func reconcileSidebarOrder() -> Bool {
        let exists: [SourceKind: Set<String>] = [
            .playlist: Set(playlists.map(\.id)),
            .channel: Set(channels.map(\.id)),
        ]
        let folderIDs = Set(folders.map(\.id))
        var placed = Set<String>()
        func key(_ ref: SourceRef) -> String { "\(ref.type.rawValue):\(ref.id)" }
        func keep(_ ref: SourceRef) -> Bool {
            guard exists[ref.type]?.contains(ref.id) == true, !placed.contains(key(ref)) else { return false }
            placed.insert(key(ref))
            return true
        }

        var next: [SidebarEntry] = []
        var promoted: [SidebarEntry] = []
        for entry in sidebarOrder {
            switch entry {
            case .folder(let id, let children):
                let kept = children.filter(keep)
                if !folderIDs.contains(id) || placed.contains("folder:\(id)") {
                    promoted.append(contentsOf: kept.map { .source($0) })
                    continue
                }
                placed.insert("folder:\(id)")
                next.append(.folder(id: id, children: kept))
            case .source(let ref):
                if keep(ref) { next.append(entry) }
            }
        }

        var missing = promoted
        for kind in [SourceKind.playlist, .channel] {
            for source in sources(kind) where !placed.contains("\(kind.rawValue):\(source.id)") {
                placed.insert("\(kind.rawValue):\(source.id)")
                missing.append(.source(SourceRef(type: kind, id: source.id)))
            }
        }
        if let firstFolder = next.firstIndex(where: \.isFolder) {
            next.insert(contentsOf: missing, at: firstFolder)
        } else {
            next.append(contentsOf: missing)
        }
        for folder in folders where !placed.contains("folder:\(folder.id)") {
            next.append(.folder(id: folder.id, children: []))
        }

        guard next != sidebarOrder else { return false }
        sidebarOrder = next
        return true
    }

    // MARK: Bookmarks, history, hidden videos

    func isBookmarked(_ videoID: String) -> Bool { bookmarks[videoID] != nil }

    func toggleBookmark(_ video: Video) {
        if bookmarks[video.id] != nil {
            bookmarks[video.id] = nil
        } else {
            bookmarks[video.id] = Bookmark(videoID: video.id, createdAt: nowMilliseconds(), video: video)
        }
        scheduleUserSave()
    }

    func addBookmark(_ video: Video) {
        bookmarks[video.id] = Bookmark(videoID: video.id, createdAt: nowMilliseconds(), video: video)
        scheduleUserSave()
    }

    func isSkipped(_ videoID: String) -> Bool { skipped.contains(videoID) }

    func setSkipped(_ videoID: String, _ value: Bool) {
        if value { skipped.insert(videoID) } else { skipped.remove(videoID) }
        scheduleUserSave()
    }

    func recordWatch(_ video: Video) {
        watchHistory.removeAll { $0.videoId == video.id }
        watchHistory.insert(HistoryEntry(videoId: video.id, title: video.title, thumbnail: video.thumbnail,
                                         duration: video.duration, watchedAt: nowMilliseconds()), at: 0)
        if watchHistory.count > Self.videoListLimit {
            watchHistory.removeLast(watchHistory.count - Self.videoListLimit)
        }
        scheduleUserSave()
    }

    func clearHistory() {
        watchHistory = []
        scheduleUserSave()
    }

    // MARK: Derived lists

    func videos(for selection: LibrarySelection) -> [Video] {
        switch selection {
        case .latest:
            return newest(channels + playlists, limit: Self.videoListLimit)
        case .folder(let id):
            let refs = folderChildren(id)
            return merged(refs.compactMap { source($0) })
        case .playlist, .channel:
            guard let ref = selection.sourceRef, let source = source(ref) else { return [] }
            var seen = Set<String>()
            return source.items.filter { seen.insert($0.id).inserted }
        case .bookmarks:
            var index: [String: Video] = [:]
            for source in playlists + channels {
                for video in source.items where index[video.id] == nil {
                    var copy = video
                    copy.sourceTitle = copy.sourceTitle ?? source.title
                    index[video.id] = copy
                }
            }
            return bookmarks.values
                .sorted { $0.createdAt > $1.createdAt }
                .compactMap { index[$0.videoID] ?? $0.video }
        case .history:
            return watchHistory.map(\.video)
        }
    }

    /// Every video of the given sources, newest first, tagged with where it
    /// came from.
    private func merged(_ sources: [Source]) -> [Video] {
        var seen = Set<String>()
        var all: [Video] = []
        for source in sources {
            for video in source.items where seen.insert(video.id).inserted {
                var copy = video
                copy.sourceTitle = copy.sourceTitle ?? source.title
                all.append(copy)
            }
        }
        return all.sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
    }

    /// The `limit` newest videos of the given sources. Only each source's own
    /// newest `limit` can make the cut, so the full library is never sorted.
    private func newest(_ sources: [Source], limit: Int) -> [Video] {
        var candidates: [(date: Double, source: Int, item: Int)] = []
        for (sourceIndex, source) in sources.enumerated() {
            var local = source.items.indices.map { (date: source.items[$0].publishedAt ?? 0, source: sourceIndex, item: $0) }
            if local.count > limit {
                local.sort { $0.date > $1.date }
                local.removeLast(local.count - limit)
            }
            candidates += local
        }
        candidates.sort { $0.date > $1.date }

        var seen = Set<String>()
        var result: [Video] = []
        for candidate in candidates {
            let source = sources[candidate.source]
            var video = source.items[candidate.item]
            guard seen.insert(video.id).inserted else { continue }
            video.sourceTitle = video.sourceTitle ?? source.title
            result.append(video)
            if result.count == limit { break }
        }
        return result
    }

    func title(for selection: LibrarySelection) -> String {
        switch selection {
        case .latest: "Latest"
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .folder(let id): folder(id)?.name ?? "Folder"
        case .playlist, .channel: selection.sourceRef.flatMap { source($0)?.title } ?? ""
        }
    }

    // MARK: Import / export

    /// The sources and folders as OPML, in sidebar order, without videos.
    func exportOPML() -> Data {
        OPML.encode(title: "Bower", order: sidebarOrder, folders: folders, source: source)
    }

    /// Merges a Bower JSON export or an OPML file into the library; anything
    /// already present is kept as is, and an imported folder joins an
    /// existing one of the same name. Returns the sources that were added.
    @discardableResult
    func importData(_ data: Data) throws -> [SourceRef] {
        let file: ExportFile
        if let json = try? JSONDecoder().decode(ExportFile.self, from: data) {
            file = json
        } else {
            file = try OPML.decode(data)
        }
        let playlistIDs = Set(playlists.map(\.id))
        let channelIDs = Set(channels.map(\.id))
        let newPlaylists = file.playlists.filter { !playlistIDs.contains($0.id) }
        let newChannels = file.channels.filter { !channelIDs.contains($0.id) }
        playlists += newPlaylists
        channels += newChannels
        let added = newPlaylists.map { SourceRef(type: .playlist, id: $0.id) }
            + newChannels.map { SourceRef(type: .channel, id: $0.id) }
        let addedSet = Set(added)

        // Imported folder id -> the folder it lands in here.
        var folderTarget: [String: String] = [:]
        for folder in file.folders ?? [] {
            if let existing = folders.first(where: { $0.id == folder.id })
                ?? folders.first(where: { $0.name.localizedCaseInsensitiveCompare(folder.name) == .orderedSame }) {
                folderTarget[folder.id] = existing.id
            } else {
                folders.append(folder)
                folderTarget[folder.id] = folder.id
            }
        }

        if let order = file.sidebarOrder {
            var fresh: [SidebarEntry] = []
            for entry in order {
                switch entry {
                case .source(let ref):
                    if addedSet.contains(ref) { fresh.append(entry) }
                case .folder(let id, let children):
                    let target = folderTarget[id] ?? id
                    let newChildren = children.filter(addedSet.contains)
                    if let index = sidebarOrder.firstIndex(where: {
                        if case .folder(target, _) = $0 { true } else { false }
                    }) {
                        if case .folder(_, let existing) = sidebarOrder[index] {
                            sidebarOrder[index] = .folder(id: target, children: existing + newChildren)
                        }
                    } else {
                        fresh.append(.folder(id: target, children: newChildren))
                    }
                }
            }
            insertAtTop(fresh)
        }
        reconcileSidebarOrder()
        scheduleLibrarySave()

        for bookmark in file.bookmarks ?? [] where bookmarks[bookmark.videoID] == nil {
            bookmarks[bookmark.videoID] = bookmark
        }
        scheduleUserSave()
        return added
    }
}

nonisolated struct ExportFile: Codable {
    var playlists: [Source]
    var channels: [Source]
    var folders: [Folder]?
    var sidebarOrder: [SidebarEntry]?
    var bookmarks: [Bookmark]?
}
