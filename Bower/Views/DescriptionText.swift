import AppKit
import SwiftUI

/// A video description with clickable timestamps (seek the player) and links
/// (open in the browser), selectable for copying.
///
/// Backed by an NSTextView rather than `Text` + `.textSelection`: selectable
/// SwiftUI text reports a minimum size that follows its width, and inside a
/// split view that made every resize step re-run layout until AppKit aborted
/// ("too many constraint passes"). Here the size is computed explicitly.
struct DescriptionText: NSViewRepresentable {
    let text: String
    let onSeek: (Int) -> Void

    private static let seekScheme = "bower-seek"
    // 0:08, 35:18, 1:09:54 — but not parts of "1.2.7" or "v1:2".
    private static let timestamp = try! NSRegularExpression(pattern: #"(?<![\d:])(\d{1,2}:)?\d{1,2}:\d{2}(?![\d:])"#)
    private static let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = context.coordinator
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onSeek = onSeek
        if context.coordinator.text != text {
            context.coordinator.text = text
            textView.textStorage?.setAttributedString(Self.attributed(text))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
        // Report nothing for the min/max probes so the column's size limits
        // never depend on the description.
        guard let width = proposal.width, width > 0, width.isFinite,
              let container = textView.textContainer, let layout = textView.layoutManager
        else { return CGSize(width: 0, height: 0) }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        return CGSize(width: width, height: height)
    }

    private static func attributed(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        let range = NSRange(location: 0, length: (text as NSString).length)
        for match in links.matches(in: text, range: range) {
            if let url = match.url { result.addAttribute(.link, value: url, range: match.range) }
        }
        for match in timestamp.matches(in: text, range: range) {
            let value = (text as NSString).substring(with: match.range)
            if let seconds = DurationText.seconds(from: value),
               let url = URL(string: "\(seekScheme)://\(seconds)") {
                result.addAttribute(.link, value: url, range: match.range)
            }
        }
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: String?
        var onSeek: (Int) -> Void = { _ in }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            if url.scheme == DescriptionText.seekScheme, let seconds = Int(url.host() ?? "") {
                onSeek(seconds)
            } else {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}
