import Foundation
import UniformTypeIdentifiers

/// Reads and writes the library as OPML: one outline per channel or playlist
/// (pointing at its YouTube feed, so RSS readers can use the file too) and
/// one per folder holding its members. Videos aren't included.
nonisolated enum OPML {
    static let contentType = UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml

    struct InvalidFile: Error {}

    static func feedURL(_ ref: SourceRef) -> String {
        switch ref.type {
        case .playlist: "https://www.youtube.com/feeds/videos.xml?playlist_id=\(ref.id)"
        case .channel: "https://www.youtube.com/feeds/videos.xml?channel_id=\(ref.id)"
        }
    }

    // MARK: Writing

    static func encode(title: String, order: [SidebarEntry], folders: [Folder], source: (SourceRef) -> Source?) -> Data {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>\(escape(title))</title>",
            "    <dateCreated>\(rfc822(Date()))</dateCreated>",
            "  </head>",
            "  <body>",
        ]
        func sourceLine(_ ref: SourceRef, indent: String) -> String? {
            guard let source = source(ref) else { return nil }
            let title = escape(source.title)
            let html = escape(Source.browserURL(kind: ref.type, id: ref.id).absoluteString)
            return #"\#(indent)<outline type="rss" text="\#(title)" title="\#(title)" xmlUrl="\#(escape(feedURL(ref)))" htmlUrl="\#(html)"/>"#
        }
        for entry in order {
            switch entry {
            case .source(let ref):
                if let line = sourceLine(ref, indent: "    ") { lines.append(line) }
            case .folder(let id, let children):
                let name = escape(folders.first { $0.id == id }?.name ?? "Folder")
                let members = children.compactMap { sourceLine($0, indent: "      ") }
                if members.isEmpty {
                    lines.append(#"    <outline text="\#(name)" title="\#(name)"/>"#)
                } else {
                    lines.append(#"    <outline text="\#(name)" title="\#(name)">"#)
                    lines += members
                    lines.append("    </outline>")
                }
            }
        }
        lines += ["  </body>", "</opml>", ""]
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    private static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: Reading

    /// Turns an OPML file into an export without videos. Outlines that aren't
    /// YouTube channels or playlists are skipped, and nested folders are
    /// flattened into their top-level folder.
    static func decode(_ data: Data) throws -> ExportFile {
        guard let document = try? XMLDocument(data: data),
              document.rootElement()?.name?.lowercased() == "opml",
              let body = document.rootElement()?.elements(forName: "body").first
        else { throw InvalidFile() }

        var file = ExportFile(playlists: [], channels: [], folders: [], sidebarOrder: [])
        var seen = Set<SourceRef>()

        func add(_ outline: XMLElement) -> SourceRef? {
            guard let ref = sourceRef(outline), seen.insert(ref).inserted else { return nil }
            let title = attribute(outline, "title") ?? attribute(outline, "text") ?? ref.id
            let source = Source(id: ref.id, title: title, thumbnail: nil, lastUpdated: 0, items: [])
            if ref.type == .playlist { file.playlists.append(source) } else { file.channels.append(source) }
            return ref
        }
        func descendants(_ outline: XMLElement) -> [SourceRef] {
            outline.elements(forName: "outline").flatMap { child in
                if let ref = add(child) { return [ref] }
                return descendants(child)
            }
        }

        for outline in body.elements(forName: "outline") {
            if let ref = add(outline) {
                file.sidebarOrder?.append(.source(ref))
            } else if !outline.elements(forName: "outline").isEmpty {
                let folder = Folder(id: UUID().uuidString.lowercased(),
                                    name: attribute(outline, "title") ?? attribute(outline, "text") ?? "Folder",
                                    isCollapsed: false)
                let children = descendants(outline)
                file.folders?.append(folder)
                file.sidebarOrder?.append(.folder(id: folder.id, children: children))
            }
        }
        return file
    }

    private static func attribute(_ element: XMLElement, _ name: String) -> String? {
        guard let value = element.attribute(forName: name)?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Recognizes YouTube feed URLs, falling back to channel or playlist page URLs.
    private static func sourceRef(_ outline: XMLElement) -> SourceRef? {
        for name in ["xmlUrl", "htmlUrl", "url"] {
            guard let string = attribute(outline, name),
                  let components = URLComponents(string: string),
                  components.host?.hasSuffix("youtube.com") == true
            else { continue }
            let query = Dictionary((components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }, uniquingKeysWith: { a, _ in a })
            if let id = query["channel_id"], id.hasPrefix("UC") { return SourceRef(type: .channel, id: id) }
            if let id = query["playlist_id"] ?? query["list"] { return SourceRef(type: .playlist, id: id) }
            let parts = components.path.split(separator: "/")
            if parts.count >= 2, parts[0] == "channel", parts[1].hasPrefix("UC") {
                return SourceRef(type: .channel, id: String(parts[1]))
            }
        }
        return nil
    }
}
