import Foundation

nonisolated enum AppPaths {
    static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: Bundle.main.bundleIdentifier ?? "me.limboy.Bower", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var library: URL { dataDirectory.appending(path: "library.json") }
    static var userData: URL { dataDirectory.appending(path: "user.json") }
    static var playback: URL { dataDirectory.appending(path: "playback.json") }
    static var descriptions: URL { dataDirectory.appending(path: "descriptions.json") }
    static var cookie: URL { dataDirectory.appending(path: "youtube-cookie.txt") }

    static var avatars: URL {
        let dir = dataDirectory.appending(path: "avatars", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

nonisolated enum JSONFile {
    /// Reads and decodes `url`. A file that exists but can't be decoded is
    /// moved aside first (`library.corrupt-<date>.json`), so the next save
    /// can't overwrite the only copy of the user's data.
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[store] could not decode \(url.lastPathComponent): \(error)")
            quarantine(url)
            return nil
        }
    }

    private static func quarantine(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "\(url.deletingPathExtension().lastPathComponent).corrupt-\(stamp).\(url.pathExtension)"
        do {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appending(path: name))
        } catch {
            print("[store] could not move aside \(url.lastPathComponent): \(error)")
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[store] could not write \(url.lastPathComponent): \(error)")
        }
    }
}
