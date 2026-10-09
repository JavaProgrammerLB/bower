import Foundation

/// Classifies what the user pasted into the Add sheet.
nonisolated enum YouTubeURL {
    enum Kind: Equatable {
        case playlist(id: String)
        case channel
        case video(id: String)
        case unsupported(String)
    }

    // Single-segment paths under youtube.com that are pages, not legacy
    // vanity channel URLs.
    private static let reservedPaths: Set<String> = [
        "watch", "playlist", "shorts", "live", "embed", "v", "results",
        "feed", "hashtag", "post", "source", "clip", "attribution_link", "oembed",
    ]

    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
            ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host() != nil else { return nil }
        return url
    }

    private static func isYouTubeHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtu.be" || host.hasSuffix(".youtu.be")
    }

    private static func segments(_ url: URL) -> [String] {
        url.path().split(separator: "/").map(String.init)
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func classify(_ text: String) -> Kind? {
        guard let url = parse(text), isYouTubeHost(url) else { return nil }
        let parts = segments(url)
        let first = parts.first?.lowercased() ?? ""

        if (first == "shorts" || first == "live"), parts.count >= 2 {
            return .unsupported("Shorts and live streams aren't supported.")
        }
        if let list = query(url, "list") {
            return .playlist(id: list)
        }
        if let id = videoID(url) {
            return .video(id: id)
        }
        if isChannel(parts) {
            return .channel
        }
        return nil
    }

    private static func videoID(_ url: URL) -> String? {
        let parts = segments(url)
        if url.host()?.lowercased().hasSuffix("youtu.be") == true {
            return parts.first
        }
        if parts.count >= 2, ["embed", "v"].contains(parts[0].lowercased()) {
            return parts[1]
        }
        return query(url, "v")
    }

    private static func isChannel(_ parts: [String]) -> Bool {
        guard let first = parts.first else { return false }
        if ["channel", "c", "user"].contains(first) { return parts.count >= 2 }
        if first.hasPrefix("@") { return true }
        return parts.count == 1 && !reservedPaths.contains(first.lowercased())
    }

    /// The `UC…` id when the URL names it directly, so no lookup is needed.
    static func directChannelID(_ text: String) -> String? {
        guard let url = parse(text) else { return nil }
        let parts = segments(url)
        guard parts.count >= 2, parts[0] == "channel", parts[1].hasPrefix("UC") else { return nil }
        return parts[1]
    }

    /// Strips tab suffixes so `/@name/videos` resolves to the channel itself.
    static func cleanedChannelURL(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.lowercased().hasPrefix("http") { value = "https://\(value)" }
        while value.hasSuffix("/") { value.removeLast() }
        for suffix in ["/featured", "/videos", "/streams", "/playlists", "/shorts"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value
    }
}
