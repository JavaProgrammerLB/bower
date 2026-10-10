import CryptoKit
import Foundation

nonisolated struct YouTubeError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

nonisolated struct ChannelSnapshot: Sendable {
    var id: String
    var title: String
    var avatarURL: String?
    var videos: [Video]
}

nonisolated struct PlaylistSnapshot: Sendable {
    var id: String
    var title: String
    var videos: [Video]
}

nonisolated struct VideoDetails: Sendable {
    var video: Video
    var description: String
}

/// A minimal InnerTube (YouTube's internal API) client for the WEB client —
/// just the calls Bower needs.
nonisolated final class InnerTubeClient: Sendable {
    static let shared = InnerTubeClient()

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let origin = "https://www.youtube.com"
    private static let clientVersion = "2.20251001.01.00"

    /// Upper bound on stored videos per source.
    static let videoCap = 500

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        // The Cookie header is set by hand from the stored value; a cookie jar
        // would add or override entries behind our back.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: Requests

    @concurrent
    private func post(_ endpoint: String, body: [String: Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"

        var payload = body
        payload["context"] = [
            "client": [
                "clientName": "WEB",
                "clientVersion": Self.clientVersion,
                // Upload dates only come back as localized relative text, so
                // the language must stay English for them to parse.
                "hl": "en",
                "gl": "US",
            ],
            "user": ["lockedSafetyMode": false],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YouTubeError("YouTube returned HTTP \(http.statusCode) for \(endpoint).")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(Self.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")

        let cookie = CookieStore.shared.cookie
        guard !cookie.isEmpty else { return }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        // Without a SAPISIDHASH the cookie is sent but the request is still
        // treated as anonymous, which is exactly what the bot check rejects.
        if let sapisid = CookieStore.shared.sapisid {
            let timestamp = Int(Date().timeIntervalSince1970)
            let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(Self.origin)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            request.setValue("SAPISIDHASH \(timestamp)_\(digest)", forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
    }

    // MARK: Channels

    @concurrent
    func resolveChannelID(_ url: String) async throws -> String {
        if let direct = YouTubeURL.directChannelID(url) { return direct }
        let json = try await post("navigation/resolve_url", body: ["url": YouTubeURL.cleanedChannelURL(url)])
        guard let id = JSONNode.string(json, "endpoint", "browseEndpoint", "browseId"), id.hasPrefix("UC") else {
            throw YouTubeError("Couldn't find a channel at that URL.")
        }
        return id
    }

    /// The channel's Videos tab, newest first. `fullHistory` follows
    /// continuations up to the cap; otherwise only the first page is read.
    @concurrent
    func channel(id: String, fullHistory: Bool) async throws -> ChannelSnapshot {
        // `params` selects the Videos tab.
        let json = try await post("browse", body: ["browseId": id, "params": "EgZ2aWRlb3PyBgQKAjoA"])

        let metadata = JSONNode.first("channelMetadataRenderer", in: json) as? [String: Any]
        guard let metadata else {
            if let alert = JSONNode.first("alertRenderer", in: json), let text = JSONNode.text(JSONNode.value(alert, "text")) {
                throw YouTubeError(text)
            }
            throw YouTubeError("This channel isn't available.")
        }
        let avatars = JSONNode.value(metadata, "avatar", "thumbnails") as? [[String: Any]]

        var page = InnerTubeParser.page(from: json)
        var videos = page.videos
        while fullHistory, videos.count < Self.videoCap, let token = page.continuation {
            page = InnerTubeParser.page(from: try await post("browse", body: ["continuation": token]))
            if page.videos.isEmpty { break }
            videos.append(contentsOf: page.videos)
        }

        return ChannelSnapshot(
            id: metadata["externalId"] as? String ?? id,
            title: metadata["title"] as? String ?? "",
            avatarURL: avatars?.last?["url"] as? String,
            videos: Self.unique(videos)
        )
    }

    // MARK: Playlists

    @concurrent
    func playlist(id: String, fullHistory: Bool) async throws -> PlaylistSnapshot {
        let json = try await post("browse", body: ["browseId": "VL\(id)"])

        let title = JSONNode.string(JSONNode.first("playlistMetadataRenderer", in: json), "title")
            ?? JSONNode.text(JSONNode.value(JSONNode.first("pageHeaderRenderer", in: json), "pageTitle"))
        guard let title else {
            if let alert = JSONNode.first("alertRenderer", in: json), let text = JSONNode.text(JSONNode.value(alert, "text")) {
                throw YouTubeError(text)
            }
            throw YouTubeError("This playlist doesn't exist or is private.")
        }

        var page = InnerTubeParser.page(from: json)
        var videos = page.videos
        while fullHistory, videos.count < Self.videoCap, let token = page.continuation {
            page = InnerTubeParser.page(from: try await post("browse", body: ["continuation": token]))
            if page.videos.isEmpty { break }
            videos.append(contentsOf: page.videos)
        }

        return PlaylistSnapshot(id: id, title: title, videos: Self.unique(videos))
    }

    private static func unique(_ videos: [Video]) -> [Video] {
        var seen = Set<String>()
        return Array(videos.filter { seen.insert($0.id).inserted }.prefix(videoCap))
    }

    // MARK: Videos

    @concurrent
    func video(id: String) async throws -> VideoDetails {
        let json = try await post("player", body: ["videoId": id])
        guard let details = JSONNode.value(json, "videoDetails") as? [String: Any],
              let title = details["title"] as? String, !title.isEmpty
        else {
            let status = JSONNode.value(json, "playabilityStatus") as? [String: Any]
            let reason = (status?["reason"] as? String) ?? (status?["status"] as? String)
            throw YouTubeError("Couldn't load video details\(reason.map { " (\($0))" } ?? ""). Please try again.")
        }
        let isLive = details["isLive"] as? Bool ?? false
        let seconds = Int(details["lengthSeconds"] as? String ?? "") ?? 0
        let duration = isLive || seconds == 0 ? "Live" : DurationText.format(seconds: seconds)
        let video = Video(id: id, title: title, thumbnail: InnerTubeParser.thumbnail(for: id), duration: duration)
        return VideoDetails(video: video, description: details["shortDescription"] as? String ?? "")
    }

    /// Whether YouTube refuses this video because it's for channel members.
    /// Asked with the user's cookie, so a member gets `false`. Lists already
    /// leave such videos out, but one saved while public can turn
    /// members-only later.
    @concurrent
    func isMembersOnly(videoID: String) async -> Bool {
        guard let json = try? await post("player", body: ["videoId": videoID]),
              let status = JSONNode.value(json, "playabilityStatus") as? [String: Any],
              status["status"] as? String != "OK"
        else { return false }
        return JSONNode.string(status, "errorScreen", "playerLegacyDesktopYpcOfferRenderer", "offerId") == "sponsors_only_video"
    }

    @concurrent
    func description(videoID: String) async -> String {
        if let details = try? await video(id: videoID), !details.description.isEmpty {
            return details.description
        }
        guard let json = try? await post("next", body: ["videoId": videoID]) else { return "" }
        return JSONNode.text(JSONNode.first("attributedDescription", in: json)) ?? ""
    }

    // MARK: Account

    /// Confirms YouTube treats requests as signed in, returning the account
    /// name when it can be read.
    @concurrent
    func verifySignedIn() async -> (signedIn: Bool, accountName: String?, detail: String?) {
        var detail: String?
        do {
            let json = try await post("account/account_menu", body: [:])
            let name = JSONNode.text(JSONNode.value(
                JSONNode.first("activeAccountHeaderRenderer", in: json), "accountName"))
            if let name, !name.isEmpty { return (true, name, nil) }
        } catch {
            detail = error.localizedDescription
        }

        // A plain page load reflects the cookie alone, separating an expired
        // cookie from a request-signing problem.
        var request = URLRequest(url: URL(string: "https://www.youtube.com/")!)
        applyHeaders(to: &request)
        if let (data, _) = try? await session.data(for: request),
           let html = String(data: data, encoding: .utf8),
           html.range(of: #""LOGGED_IN"\s*:\s*true"#, options: .regularExpression) != nil {
            return (true, nil, nil)
        }
        return (false, nil, detail ?? "YouTube answered as if signed out")
    }

    @concurrent
    func downloadData(from url: URL) async throws -> (Data, String?) {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YouTubeError("Download failed")
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type"))
    }
}
