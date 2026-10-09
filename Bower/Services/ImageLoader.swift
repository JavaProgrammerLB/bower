import AppKit
import SwiftUI

/// Channel avatars live on disk so the sidebar renders offline and does not
/// depend on short-lived googleusercontent URLs. They are referenced as
/// `bower-avatar://<file>`.
nonisolated enum AvatarCache {
    static let prefix = "bower-avatar://"

    static func isLocal(_ value: String?) -> Bool {
        value?.hasPrefix(prefix) == true
    }

    static func fileURL(for value: String) -> URL? {
        guard isLocal(value) else { return nil }
        let name = (String(value.dropFirst(prefix.count)) as NSString).lastPathComponent
        return name.isEmpty ? nil : AppPaths.avatars.appending(path: name)
    }

    /// Returns a local reference for the channel's avatar, downloading only
    /// when no file backs the reference we already hold.
    @concurrent
    static func ensure(channelID: String, remoteURL: String?, existing: String?) async -> String? {
        if let existing, let file = fileURL(for: existing), FileManager.default.fileExists(atPath: file.path) {
            return existing
        }
        guard let remoteURL, let url = URL(string: remoteURL) else {
            return isLocal(existing) ? nil : existing
        }
        guard let (data, contentType) = try? await InnerTubeClient.shared.downloadData(from: url) else { return existing }

        let ext = switch contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "image/png": ".png"
        case "image/webp": ".webp"
        case "image/gif": ".gif"
        default: ".jpg"
        }
        let name = channelID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } + ext
        do {
            try data.write(to: AppPaths.avatars.appending(path: name), options: .atomic)
            return prefix + name
        } catch {
            return existing
        }
    }

    /// Deletes avatar files of channels no longer in the library.
    static func prune(keeping references: [String]) {
        let keep = Set(references.compactMap { fileURL(for: $0)?.lastPathComponent })
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: AppPaths.avatars.path) else { return }
        for file in files where !keep.contains(file) {
            try? FileManager.default.removeItem(at: AppPaths.avatars.appending(path: file))
        }
    }
}

/// Loads thumbnails and avatars, with an in-memory cache in front of a disk
/// URL cache.
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, NSImage>()
    private let session: URLSession
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        memory.countLimit = 800
        let config = URLSessionConfiguration.default
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "BowerImages")
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20, directory: cacheDir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    func cached(_ key: String) -> NSImage? {
        memory.object(forKey: key as NSString)
    }

    func image(for key: String) async -> NSImage? {
        if let hit = cached(key) { return hit }
        if let task = inFlight[key] { return await task.value }

        let session = session
        let task = Task<NSImage?, Never> {
            let data: Data?
            if let file = AvatarCache.fileURL(for: key) {
                data = try? Data(contentsOf: file)
            } else if let url = URL(string: key) {
                data = try? await session.data(from: url).0
            } else {
                data = nil
            }
            return data.flatMap(NSImage.init(data:))
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, !url.isEmpty else {
                image = nil
                return
            }
            if let hit = ImageLoader.shared.cached(url) {
                image = hit
                return
            }
            image = nil
            image = await ImageLoader.shared.image(for: url)
        }
    }
}

extension RemoteImage where Placeholder == Color {
    init(url: String?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = { Color.secondary.opacity(0.15) }
    }
}
