import Foundation
import Observation

nonisolated struct RefreshFailure: Identifiable, Sendable {
    var id: String { "\(ref.type.rawValue):\(ref.id)" }
    var ref: SourceRef
    var title: String
    var message: String
}

/// Adds sources and keeps them up to date.
@Observable
final class LibraryService {
    private(set) var isRefreshing = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var refreshingRefs: Set<SourceRef> = []
    var failures: [RefreshFailure] = []

    @ObservationIgnored private let store: LibraryStore
    private static let staleInterval: TimeInterval = 60 * 60
    private static let maxConcurrent = 4

    init(store: LibraryStore) {
        self.store = store
    }

    private nonisolated enum Fetched: Sendable {
        case playlist(PlaylistSnapshot)
        case channel(ChannelSnapshot, avatar: String?)
    }

    // MARK: Refresh

    /// Checks for new uploads when the last check was over an hour ago.
    func refreshIfStale() {
        guard !isRefreshing, !store.isEmpty else { return }
        if let last = store.lastRefresh, Date().timeIntervalSince(last) < Self.staleInterval { return }
        refreshAll(full: false)
    }

    /// `full` re-reads every source's whole history instead of just looking
    /// for new videos at the top.
    func refreshAll(full: Bool) {
        let refs = store.playlists.map { SourceRef(type: .playlist, id: $0.id) }
            + store.channels.map { SourceRef(type: .channel, id: $0.id) }
        refresh(refs, full: full, markComplete: true)
    }

    func refresh(_ ref: SourceRef, full: Bool = false) {
        refresh([ref], full: full, markComplete: false)
    }

    private func refresh(_ refs: [SourceRef], full: Bool, markComplete: Bool) {
        guard !isRefreshing, !refs.isEmpty else { return }
        isRefreshing = true
        completed = 0
        total = refs.count
        failures = []

        Task {
            await withTaskGroup(of: (SourceRef, Result<Fetched, Error>).self) { group in
                var pending = refs[...]
                var running = 0
                while true {
                    while running < Self.maxConcurrent, let ref = pending.popFirst() {
                        running += 1
                        refreshingRefs.insert(ref)
                        let existingThumbnail = store.source(ref)?.thumbnail
                        group.addTask {
                            do {
                                return (ref, .success(try await Self.fetch(ref, full: full, existingThumbnail: existingThumbnail)))
                            } catch {
                                return (ref, .failure(error))
                            }
                        }
                    }
                    guard let (ref, result) = await group.next() else { break }
                    running -= 1
                    refreshingRefs.remove(ref)
                    completed += 1
                    switch result {
                    case .success(let fetched): merge(fetched, into: ref, full: full)
                    case .failure(let error):
                        failures.append(RefreshFailure(ref: ref, title: store.source(ref)?.title ?? ref.id,
                                                       message: error.localizedDescription))
                    }
                }
            }
            if markComplete { store.lastRefresh = Date() }
            isRefreshing = false
        }
    }

    @concurrent
    private static func fetch(_ ref: SourceRef, full: Bool, existingThumbnail: String?) async throws -> Fetched {
        let client = InnerTubeClient.shared
        switch ref.type {
        case .playlist:
            return .playlist(try await client.playlist(id: ref.id, fullHistory: full))
        case .channel:
            let snapshot = try await client.channel(id: ref.id, fullHistory: full)
            let avatar = await AvatarCache.ensure(channelID: snapshot.id, remoteURL: snapshot.avatarURL, existing: existingThumbnail)
            return .channel(snapshot, avatar: avatar)
        }
    }

    private func merge(_ fetched: Fetched, into ref: SourceRef, full: Bool) {
        guard var source = store.source(ref) else { return }
        let fresh: [Video]
        switch fetched {
        case .playlist(let snapshot):
            fresh = snapshot.videos
            if !snapshot.title.isEmpty { source.title = snapshot.title }
            if let first = snapshot.videos.first { source.thumbnail = first.thumbnail }
        case .channel(let snapshot, let avatar):
            fresh = snapshot.videos
            if !snapshot.title.isEmpty { source.title = snapshot.title }
            if let avatar { source.thumbnail = avatar }
        }

        if full {
            if !fresh.isEmpty { source.items = fresh }
        } else {
            let stored = Set(source.items.map(\.id))
            let added = fresh.filter { !stored.contains($0.id) }
            source.items = Array((added + source.items).prefix(InnerTubeClient.videoCap))
        }
        source.lastUpdated = nowMilliseconds()
        store.upsert(source, kind: ref.type)
    }

    // MARK: Adding

    nonisolated struct Added: Sendable {
        var selection: LibrarySelection
        var videoID: String?
    }

    /// Adds whatever the URL points at: a playlist or channel joins the
    /// library; a single video is bookmarked.
    func add(_ text: String) async throws -> Added {
        guard let kind = YouTubeURL.classify(text) else {
            throw YouTubeError("That isn't a YouTube playlist, channel, or video URL.")
        }
        let client = InnerTubeClient.shared

        switch kind {
        case .unsupported(let reason):
            throw YouTubeError(reason)

        case .playlist(let id):
            if let existing = store.source(SourceRef(type: .playlist, id: id)) {
                throw YouTubeError("“\(existing.title)” is already in your library.")
            }
            let snapshot = try await client.playlist(id: id, fullHistory: true)
            store.upsert(Source(id: id, title: snapshot.title, thumbnail: snapshot.videos.first?.thumbnail,
                                lastUpdated: nowMilliseconds(), items: snapshot.videos), kind: .playlist)
            return Added(selection: .playlist(id))

        case .video(let id):
            let details = try await client.video(id: id)
            store.addBookmark(details.video)
            return Added(selection: .bookmarks, videoID: id)

        case .channel:
            let id = try await client.resolveChannelID(text)
            if let existing = store.source(SourceRef(type: .channel, id: id)) {
                throw YouTubeError("“\(existing.title)” is already in your library.")
            }
            let snapshot = try await client.channel(id: id, fullHistory: true)
            let avatar = await AvatarCache.ensure(channelID: snapshot.id, remoteURL: snapshot.avatarURL, existing: nil)
            store.upsert(Source(id: snapshot.id, title: snapshot.title, thumbnail: avatar,
                                lastUpdated: nowMilliseconds(), items: snapshot.videos), kind: .channel)
            return Added(selection: .channel(snapshot.id))
        }
    }
}
