import Foundation

/// A video as stored in the library. `publishedAt` is milliseconds since 1970.
nonisolated struct Video: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var thumbnail: String
    var duration: String
    var publishedAt: Double?
    var sourceTitle: String?

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }

    var publishedDate: Date? {
        publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

nonisolated enum SourceKind: String, Codable, Hashable, Sendable {
    case playlist
    case channel
}

/// A playlist or a channel together with the videos fetched for it.
nonisolated struct Source: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var thumbnail: String?
    var lastUpdated: Double
    var items: [Video]

    static func browserURL(kind: SourceKind, id: String) -> URL {
        switch kind {
        case .playlist: URL(string: "https://www.youtube.com/playlist?list=\(id)")!
        case .channel: URL(string: "https://www.youtube.com/channel/\(id)")!
        }
    }
}

nonisolated struct Folder: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var isCollapsed: Bool
}

nonisolated struct SourceRef: Codable, Hashable, Sendable {
    var type: SourceKind
    var id: String
}

/// One top-level row of the sidebar, encoded as `{type, id}` or
/// `{type: "folder", id, children}`.
nonisolated enum SidebarEntry: Codable, Hashable, Sendable {
    case source(SourceRef)
    case folder(id: String, children: [SourceRef])

    private enum CodingKeys: String, CodingKey { case type, id, children }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let id = try container.decode(String.self, forKey: .id)
        if type == "folder" {
            let children = try container.decodeIfPresent([SourceRef].self, forKey: .children) ?? []
            self = .folder(id: id, children: children)
        } else if let kind = SourceKind(rawValue: type) {
            self = .source(SourceRef(type: kind, id: id))
        } else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown sidebar entry type \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .source(let ref):
            try container.encode(ref.type.rawValue, forKey: .type)
            try container.encode(ref.id, forKey: .id)
        case .folder(let id, let children):
            try container.encode("folder", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(children, forKey: .children)
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

nonisolated struct Bookmark: Codable, Hashable, Sendable {
    var videoID: String
    var createdAt: Double
    /// Present for videos added by URL, which belong to no stored source.
    var video: Video?
}

nonisolated struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    var videoId: String
    var title: String
    var thumbnail: String
    var duration: String
    var watchedAt: Double

    var id: String { videoId }

    var video: Video {
        Video(id: videoId, title: title, thumbnail: thumbnail, duration: duration)
    }
}

nonisolated struct PlaybackPosition: Codable, Hashable, Sendable {
    var position: Double
    var duration: Double
    var updatedAt: Double
}

/// What the sidebar has selected, which is also what the video list shows.
nonisolated enum LibrarySelection: Hashable, Sendable {
    case latest
    case bookmarks
    case history
    case playlist(String)
    case channel(String)
    case folder(String)

    var sourceRef: SourceRef? {
        switch self {
        case .playlist(let id): SourceRef(type: .playlist, id: id)
        case .channel(let id): SourceRef(type: .channel, id: id)
        default: nil
        }
    }

    init(_ ref: SourceRef) {
        switch ref.type {
        case .playlist: self = .playlist(ref.id)
        case .channel: self = .channel(ref.id)
        }
    }
}

nonisolated enum LoopMode: String, Sendable, CaseIterable {
    case off, all, one

    var next: LoopMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

nonisolated func nowMilliseconds() -> Double {
    (Date().timeIntervalSince1970 * 1000).rounded()
}
