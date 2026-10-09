import Foundation

/// Helpers for walking InnerTube's JSON. The response layout shifts often
/// (renderers become view models, rows move around), so extraction searches by
/// node name rather than following fixed paths.
nonisolated enum JSONNode {
    static func value(_ node: Any?, _ path: String...) -> Any? {
        var current = node
        for key in path {
            if let index = Int(key), let array = current as? [Any] {
                current = array.indices.contains(index) ? array[index] : nil
            } else {
                current = (current as? [String: Any])?[key]
            }
        }
        return current
    }

    static func string(_ node: Any?, _ path: String...) -> String? {
        var current = node
        for key in path {
            if let index = Int(key), let array = current as? [Any] {
                current = array.indices.contains(index) ? array[index] : nil
            } else {
                current = (current as? [String: Any])?[key]
            }
        }
        return current as? String
    }

    /// `{simpleText}`, `{runs:[{text}]}` or `{content}` → plain text.
    static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return node as? String }
        if let simple = dict["simpleText"] as? String { return simple }
        if let content = dict["content"] as? String { return content }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    static func first(_ key: String, in node: Any) -> Any? {
        if let dict = node as? [String: Any] {
            if let hit = dict[key] { return hit }
            for value in dict.values {
                if let hit = first(key, in: value) { return hit }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let hit = first(key, in: value) { return hit }
            }
        }
        return nil
    }

    static func all(_ key: String, in node: Any, into results: inout [Any]) {
        if let dict = node as? [String: Any] {
            for (k, value) in dict {
                if k == key { results.append(value) }
                all(key, in: value, into: &results)
            }
        } else if let array = node as? [Any] {
            for value in array { all(key, in: value, into: &results) }
        }
    }
}

nonisolated enum InnerTubeParser {
    private static let itemKeys: Set<String> = [
        "lockupViewModel", "videoRenderer", "playlistVideoRenderer", "gridVideoRenderer", "richItemRenderer",
    ]

    struct Page {
        var videos: [Video] = []
        var continuation: String?
    }

    /// Videos on one page of a channel's Videos tab or a playlist, plus the
    /// token for the next page. The token is taken only from the list that
    /// holds the videos: the same response carries other continuations (sort
    /// chips, engagement panels) that lead elsewhere.
    static func page(from json: Any) -> Page {
        var page = Page()
        var seen = Set<String>()
        walk(json, page: &page, seen: &seen)
        return page
    }

    private static func walk(_ node: Any, page: inout Page, seen: inout Set<String>) {
        if let array = node as? [Any] {
            let holdsItems = array.contains { element in
                guard let dict = element as? [String: Any] else { return false }
                return dict.keys.contains(where: itemKeys.contains)
            }
            for element in array {
                if holdsItems, page.continuation == nil, let dict = element as? [String: Any],
                   let token = continuationToken(dict) {
                    page.continuation = token
                    continue
                }
                walk(element, page: &page, seen: &seen)
            }
            return
        }

        guard let dict = node as? [String: Any] else { return }

        if let lockup = dict["lockupViewModel"] as? [String: Any] {
            if let video = parseLockup(lockup), seen.insert(video.id).inserted { page.videos.append(video) }
            return
        }
        for key in ["videoRenderer", "gridVideoRenderer", "playlistVideoRenderer"] {
            if let renderer = dict[key] as? [String: Any] {
                if let video = parseRenderer(renderer), seen.insert(video.id).inserted { page.videos.append(video) }
                return
            }
        }
        for value in dict.values { walk(value, page: &page, seen: &seen) }
    }

    private static func continuationToken(_ element: [String: Any]) -> String? {
        guard let holder = element["continuationItemRenderer"] ?? element["continuationItemViewModel"] else { return nil }
        var commands: [Any] = []
        JSONNode.all("continuationCommand", in: holder, into: &commands)
        return commands.lazy.compactMap { ($0 as? [String: Any])?["token"] as? String }.first
    }

    static func thumbnail(for videoID: String) -> String {
        "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
    }

    private static func parseLockup(_ lockup: [String: Any]) -> Video? {
        guard let type = lockup["contentType"] as? String, type.contains("VIDEO"),
              let id = lockup["contentId"] as? String,
              let title = JSONNode.text(JSONNode.value(lockup, "metadata", "lockupMetadataViewModel", "title")),
              !title.isEmpty
        else { return nil }

        if isMembersOnly(lockup) { return nil }

        var badges: [Any] = []
        JSONNode.all("thumbnailBadgeViewModel", in: lockup["contentImage"] ?? [:], into: &badges)
        let badgeTexts = badges.compactMap { ($0 as? [String: Any])?["text"] as? String }
        let duration = badgeTexts.first { $0.contains(":") } ?? "Live"

        var publishedAt: Double?
        var parts: [Any] = []
        JSONNode.all("metadataParts", in: lockup["metadata"] ?? [:], into: &parts)
        outer: for case let list as [Any] in parts {
            for part in list {
                if let text = JSONNode.text(JSONNode.value(part, "text")), let date = RelativeTime.parse(text) {
                    publishedAt = date
                    break outer
                }
            }
        }

        return Video(id: id, title: title, thumbnail: thumbnail(for: id), duration: duration, publishedAt: publishedAt)
    }

    private static func isMembersOnly(_ node: Any) -> Bool {
        var badges: [Any] = []
        JSONNode.all("badgeText", in: node, into: &badges)
        if badges.contains(where: { ($0 as? String)?.localizedCaseInsensitiveContains("members only") == true }) { return true }
        var styles: [Any] = []
        JSONNode.all("style", in: node, into: &styles)
        return styles.contains { ($0 as? String) == "BADGE_STYLE_TYPE_MEMBERS_ONLY" }
    }

    private static func parseRenderer(_ renderer: [String: Any]) -> Video? {
        guard let id = renderer["videoId"] as? String,
              let title = JSONNode.text(renderer["title"]), !title.isEmpty
        else { return nil }
        if isMembersOnly(renderer["badges"] ?? []) { return nil }

        let duration = JSONNode.text(renderer["lengthText"]) ?? "Live"
        var published = JSONNode.text(renderer["publishedTimeText"]) ?? ""
        if published.isEmpty, let info = JSONNode.text(renderer["videoInfo"]) { published = info }

        return Video(id: id, title: title, thumbnail: thumbnail(for: id), duration: duration,
                     publishedAt: RelativeTime.parse(published))
    }
}
