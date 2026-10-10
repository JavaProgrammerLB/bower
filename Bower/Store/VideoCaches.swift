import Foundation

/// Resume positions, one per partially watched video. Capped by count and age
/// so the file stays small.
final class PlaybackPositions {
    private static let limit = 500
    private static let maxAge: Double = 90 * 24 * 60 * 60 * 1000

    private var positions: [String: PlaybackPosition]
    private var saveTask: Task<Void, Never>?

    init() {
        let stored = JSONFile.read([String: PlaybackPosition].self, from: AppPaths.playback) ?? [:]
        let cutoff = nowMilliseconds() - Self.maxAge
        positions = stored.filter { $0.value.updatedAt >= cutoff }
    }

    func position(for videoID: String) -> Double? {
        positions[videoID]?.position
    }

    func save(_ videoID: String, position: Double, duration: Double) {
        guard duration > 0 else { return }
        // Resuming only helps mid-video; near either end the entry is dropped.
        if position < 5 || duration - position < 10 {
            clear(videoID)
            return
        }
        positions[videoID] = PlaybackPosition(position: position, duration: duration, updatedAt: nowMilliseconds())
        evict()
        scheduleSave()
    }

    func clear(_ videoID: String) {
        guard positions.removeValue(forKey: videoID) != nil else { return }
        scheduleSave()
    }

    private func evict() {
        guard positions.count > Self.limit else { return }
        let oldest = positions.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(positions.count - Self.limit)
        oldest.forEach { positions[$0.key] = nil }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = positions
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            JSONFile.write(snapshot, to: AppPaths.playback)
        }
    }

    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        JSONFile.write(positions, to: AppPaths.playback)
    }
}

nonisolated struct DescriptionEntry: Codable, Sendable {
    var text: String
    var updatedAt: Double
}

/// Video descriptions, cached so a replay shows one at once.
final class DescriptionCache {
    private static let limit = 500
    private var entries: [String: DescriptionEntry]
    private var saveTask: Task<Void, Never>?

    init() {
        entries = JSONFile.read([String: DescriptionEntry].self, from: AppPaths.descriptions) ?? [:]
    }

    func cached(_ videoID: String) -> String? {
        entries[videoID]?.text
    }

    func store(_ text: String, for videoID: String) {
        guard !text.isEmpty else { return }
        entries[videoID] = DescriptionEntry(text: text, updatedAt: nowMilliseconds())
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(entries.count - Self.limit)
            oldest.forEach { entries[$0.key] = nil }
        }
        // Debounced like the other stores, so writes land in order.
        saveTask?.cancel()
        let snapshot = entries
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot)
        }
    }

    @concurrent
    private static func write(_ snapshot: [String: DescriptionEntry]) async {
        JSONFile.write(snapshot, to: AppPaths.descriptions)
    }

    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        JSONFile.write(entries, to: AppPaths.descriptions)
    }
}
