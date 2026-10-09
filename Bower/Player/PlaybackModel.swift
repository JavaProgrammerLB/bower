import Foundation
import Observation

/// What is playing and what plays next. The queue is the list a video was
/// started from, so browsing other lists in the sidebar does not interrupt
/// playback — the same model as Music.
@Observable
final class PlaybackModel {
    let player = YouTubePlayer()

    private(set) var current: Video?
    private(set) var queue: [Video] = []
    private(set) var queueContext: LibrarySelection?

    var shuffle = false {
        didSet { if shuffle != oldValue { rebuildShuffleOrder() } }
    }
    var loopMode: LoopMode = .off

    private(set) var descriptionText = ""
    private(set) var isLoadingDescription = false

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let positions = PlaybackPositions()
    @ObservationIgnored private let descriptions = DescriptionCache()
    @ObservationIgnored private var shuffledIDs: [String] = []
    @ObservationIgnored private var lastPositionSave = Date.distantPast
    @ObservationIgnored private var descriptionTask: Task<Void, Never>?

    init(store: LibraryStore) {
        self.store = store
        player.onEnded = { [weak self] in self?.videoEnded() }
        player.onStartedPlaying = { [weak self] in self?.startedPlaying() }
        player.onProgress = { [weak self] time, duration in self?.progress(time: time, duration: duration) }
    }

    // MARK: Starting playback

    /// Plays `video`, making `list` the queue.
    func play(_ video: Video, from list: [Video], context: LibrarySelection, autoplay: Bool = true) {
        let contextChanged = queueContext != context
        queue = list
        queueContext = context
        if shuffle && (contextChanged || !shuffledIDs.contains(video.id)) {
            current = video
            rebuildShuffleOrder()
        }
        start(video, autoplay: autoplay)
    }

    /// Keeps the queue in step when the library behind it changes.
    func libraryChanged(_ list: [Video], context: LibrarySelection) {
        guard queueContext == context else { return }
        queue = list
        if shuffle {
            let ids = Set(list.map(\.id))
            shuffledIDs.removeAll { !ids.contains($0) }
            let missing = list.map(\.id).filter { !shuffledIDs.contains($0) }.shuffled()
            shuffledIDs.append(contentsOf: missing)
        }
    }

    private func start(_ video: Video, autoplay: Bool) {
        let resume = positions.position(for: video.id)
        current = video
        player.load(videoID: video.id, startAt: resume, autoplay: autoplay)
        loadDescription(for: video.id)
    }

    // MARK: Transport

    var canGoNext: Bool { nextVideo(wrapping: true) != nil }
    var canGoPrevious: Bool { previousVideo() != nil }

    func next() {
        if let video = nextVideo(wrapping: true) { start(video, autoplay: true) }
    }

    func previous() {
        if player.currentTime > 5 {
            player.seek(to: 0)
        } else if let video = previousVideo() {
            start(video, autoplay: true)
        }
    }

    func togglePlayPause() {
        if current == nil, let first = queue.first {
            start(first, autoplay: true)
        } else {
            player.togglePlayPause()
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: seconds)
    }

    private var order: [Video] {
        guard shuffle else { return queue }
        let byID = Dictionary(queue.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return shuffledIDs.compactMap { byID[$0] }
    }

    private func nextVideo(wrapping: Bool) -> Video? {
        let list = order
        guard !list.isEmpty else { return nil }
        let index = current.flatMap { video in list.firstIndex { $0.id == video.id } } ?? -1
        if let found = list[(index + 1)...].first(where: { !store.isSkipped($0.id) }) { return found }
        guard wrapping, loopMode == .all else { return nil }
        return list.first { !store.isSkipped($0.id) && $0.id != current?.id }
    }

    private func previousVideo() -> Video? {
        let list = order
        guard let current, let index = list.firstIndex(where: { $0.id == current.id }), index > 0 else { return nil }
        return list[..<index].last { !store.isSkipped($0.id) }
    }

    private func rebuildShuffleOrder() {
        guard shuffle else {
            shuffledIDs = []
            return
        }
        var ids = queue.map(\.id).shuffled()
        if let current, let index = ids.firstIndex(of: current.id) {
            ids.remove(at: index)
            ids.insert(current.id, at: 0)
        }
        shuffledIDs = ids
    }

    // MARK: Player events

    private func videoEnded() {
        guard let current else { return }
        positions.clear(current.id)
        if loopMode == .one {
            player.restart()
        } else if let video = nextVideo(wrapping: true) {
            start(video, autoplay: true)
        }
    }

    private func startedPlaying() {
        guard let current, queueContext != .history else { return }
        store.recordWatch(current)
    }

    private func progress(time: Double, duration: Double) {
        guard let current, Date().timeIntervalSince(lastPositionSave) >= 5 else { return }
        lastPositionSave = Date()
        positions.save(current.id, position: time, duration: duration)
    }

    /// Hiding the playing video moves on to the next one.
    func hide(_ video: Video) {
        store.setSkipped(video.id, true)
        if video.id == current?.id, player.isPlaying { next() }
    }

    // MARK: Description

    private func loadDescription(for videoID: String) {
        descriptionTask?.cancel()
        descriptionText = ""
        isLoadingDescription = true
        descriptionTask = Task {
            let text = await descriptions.description(for: videoID)
            guard !Task.isCancelled, current?.id == videoID else { return }
            descriptionText = text
            isLoadingDescription = false
        }
    }

    func flush() {
        if let current, player.duration > 0 {
            positions.save(current.id, position: player.currentTime, duration: player.duration)
        }
        positions.flush()
    }
}
