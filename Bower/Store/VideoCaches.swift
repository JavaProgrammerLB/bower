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

/// Video descriptions, cached because fetching one costs a full player request.
final class DescriptionCache {
    private static let limit = 500
    private var entries: [String: DescriptionEntry]
    private var inFlight: [String: Task<String, Never>] = [:]

    init() {
        entries = JSONFile.read([String: DescriptionEntry].self, from: AppPaths.descriptions) ?? [:]
    }

    func description(for videoID: String) async -> String {
        if let cached = entries[videoID] { return cached.text }
        if let task = inFlight[videoID] { return await task.value }

        let task = Task { await InnerTubeClient.shared.description(videoID: videoID) }
        inFlight[videoID] = task
        let text = await task.value
        inFlight[videoID] = nil

        if !text.isEmpty {
            entries[videoID] = DescriptionEntry(text: text, updatedAt: nowMilliseconds())
            if entries.count > Self.limit {
                let oldest = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(entries.count - Self.limit)
                oldest.forEach { entries[$0.key] = nil }
            }
            let snapshot = entries
            Task.detached(priority: .utility) { JSONFile.write(snapshot, to: AppPaths.descriptions) }
        }
        return text
    }
}
