import SwiftUI

/// A video description with clickable timestamps (seek the player) and links
/// (open in the browser).
struct DescriptionText: View {
    let text: String
    let onSeek: (Int) -> Void

    private static let seekScheme = "bower-seek"
    // 0:08, 35:18, 1:09:54 — but not parts of "1.2.7" or "v1:2".
    private static let timestamp = try! NSRegularExpression(pattern: #"(?<![\d:])(\d{1,2}:)?\d{1,2}:\d{2}(?![\d:])"#)
    private static let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    var body: some View {
        Text(attributed)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == Self.seekScheme, let seconds = Int(url.host() ?? "") {
                    onSeek(seconds)
                    return .handled
                }
                return .systemAction
            })
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        func apply(_ nsRange: NSRange, url: URL, accent: Bool) {
            guard let swiftRange = Range(nsRange, in: text),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result)
            else { return }
            result[lower..<upper].link = url
            if accent { result[lower..<upper].foregroundColor = .accentColor }
        }

        for match in Self.links.matches(in: text, range: range) {
            if let url = match.url { apply(match.range, url: url, accent: false) }
        }
        for match in Self.timestamp.matches(in: text, range: range) {
            let value = ns.substring(with: match.range)
            if let seconds = DurationText.seconds(from: value),
               let url = URL(string: "\(Self.seekScheme)://\(seconds)") {
                apply(match.range, url: url, accent: true)
            }
        }
        return result
    }
}
