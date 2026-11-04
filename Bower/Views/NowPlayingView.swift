import AppKit
import ObjectiveC
import SwiftUI
import WebKit

struct NowPlayingView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        Group {
            if let video = playback.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PlayerSurface(player: playback.player)
                            .modifier(PlayerFrame(expanded: playback.player.needsSignIn))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

                        if let message = playback.player.errorMessage {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Label(message, systemImage: "person.crop.circle.badge.exclamationmark")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if playback.player.needsSignIn {
                                    Button("Sign in to YouTube") { playback.player.signInForPlayback() }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                }
                            }
                        }

                        VideoHeader(video: video)

                        Divider()

                        DescriptionSection()
                    }
                    .padding(24)
                    .frame(maxWidth: 1280)
                    .frame(maxWidth: .infinity)
                }
            } else {
                emptyState
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var emptyState: some View {
        if app.store.isEmpty {
            ContentUnavailableView {
                Label("Welcome to Bower", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text("Follow YouTube channels and playlists without the algorithm. Paste a link to get started.")
            } actions: {
                Button("Add Playlist, Channel, or Video…") { app.activeSheet = .add }
                    .buttonStyle(.borderedProminent)
                Button("Import Library…") { app.importLibrary() }
            }
        } else {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "play.slash")
            } description: {
                Text(emptyMessage)
            }
        }
    }

    private var emptyTitle: String {
        switch app.selection {
        case .bookmarks: "No Bookmarks"
        case .history: "No History"
        default: "No Videos"
        }
    }

    private var emptyMessage: String {
        switch app.selection {
        case .bookmarks: "Bookmark videos from any list, or add a single video by its URL."
        case .history: "Videos you watch will show up here."
        default: "Nothing to play here yet."
        }
    }
}

private struct VideoHeader: View {
    @Environment(AppModel.self) private var app
    let video: Video

    var body: some View {
        let playback = app.playback
        let isBookmarked = app.store.isBookmarked(video.id)

        VStack(alignment: .leading, spacing: 10) {
            Button {
                NSWorkspace.shared.open(video.watchURL)
            } label: {
                Text(video.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open in YouTube")

            HStack(spacing: 6) {
                let details = [video.sourceTitle, RelativeTime.format(video.publishedDate).nilIfEmpty, video.duration]
                    .compactMap { $0 }
                Text(details.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }

            HStack(spacing: 10) {
                ControlGroup {
                    Button { playback.previous() } label: { Label("Previous", systemImage: "backward.fill") }
                        .disabled(!playback.canGoPrevious && playback.player.currentTime <= 5)
                    Button { playback.togglePlayPause() } label: {
                        Label(playback.player.isPlaying ? "Pause" : "Play",
                              systemImage: playback.player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { playback.next() } label: { Label("Next", systemImage: "forward.fill") }
                        .disabled(!playback.canGoNext)
                }
                .controlGroupStyle(.navigation)
                .fixedSize()

                ControlGroup {
                    Button { playback.shuffle.toggle() } label: {
                        Label {
                            Text("Shuffle")
                        } icon: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(playback.shuffle ? Color.accentColor : .primary)
                        }
                    }
                    .help(playback.shuffle ? "Shuffle: On" : "Shuffle: Off")
                    Button { playback.loopMode = playback.loopMode.next } label: {
                        Label {
                            Text("Repeat")
                        } icon: {
                            Image(systemName: playback.loopMode == .one ? "repeat.1" : "repeat")
                                .foregroundStyle(playback.loopMode == .off ? Color.primary : Color.accentColor)
                        }
                    }
                    .help(repeatHelp(playback.loopMode))
                }
                .controlGroupStyle(.navigation)
                .fixedSize()

                Spacer()

                Button {
                    app.store.toggleBookmark(video)
                } label: {
                    Label(isBookmarked ? "Bookmarked" : "Bookmark", systemImage: isBookmarked ? "bookmark.fill" : "bookmark")
                }
                .help(isBookmarked ? "Remove Bookmark (⌘D)" : "Bookmark (⌘D)")

                ShareLink(item: video.watchURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }

                Button {
                    NSWorkspace.shared.open(video.watchURL)
                } label: {
                    Label("Open in YouTube", systemImage: "safari")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.large)
            // The row reports a minimum far wider than it draws (~270pt more),
            // which pushed the columns past the window's minimum width.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func repeatHelp(_ mode: LoopMode) -> String {
        switch mode {
        case .off: "Repeat: Off"
        case .all: "Repeat: All"
        case .one: "Repeat: One"
        }
    }
}

private struct DescriptionSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        Group {
            if playback.isLoadingDescription {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading description…").foregroundStyle(.secondary)
                }
            } else if playback.descriptionText.isEmpty {
                Text("No description available")
                    .foregroundStyle(.tertiary)
            } else {
                DescriptionText(text: playback.descriptionText) { seconds in
                    playback.seek(to: Double(seconds))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Taller while YouTube's own sign-in page is on screen, so the form is not
/// cropped to the 16:9 player.
private struct PlayerFrame: ViewModifier {
    var expanded: Bool

    func body(content: Content) -> some View {
        content
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: expanded ? 680 : nil)
    }
}

/// Hosts the player's single WKWebView. SwiftUI may rebuild this container;
/// the web view itself (and whatever is playing) survives.
struct PlayerSurface: NSViewRepresentable {
    let player: YouTubePlayer

    func makeCoordinator() -> Coordinator { Coordinator(player) }

    func makeNSView(context: Context) -> NSView {
        let container = PlayerHostView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        // After this layout pass. Attaching the page during the pass that
        // swaps the grid for the player is what overflows AppKit.
        Self.attachLater(player.webView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard player.webView.superview !== container else { return }
        Self.attachLater(player.webView, to: container)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        let webView = coordinator.player.webView
        guard webView.superview === nsView else { return }
        // Keep this host alive through the current constraint pass. Removing
        // the page in the pass that swaps in the grid makes AppKit abort.
        objc_setAssociatedObject(webView, &PlaybackParking.retainKey, nsView, .OBJC_ASSOCIATION_RETAIN)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if webView.superview === nsView {
                PlaybackParking.hold(webView)
            }
            objc_setAssociatedObject(webView, &PlaybackParking.retainKey, nil, .OBJC_ASSOCIATION_ASSIGN)
        }
    }

    private static func attachLater(_ webView: WKWebView, to container: NSView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak container] in
            guard let container, container.window != nil else { return }
            guard webView.superview !== container else { return }
            attach(webView, to: container)
        }
    }

    private static func attach(_ webView: WKWebView, to container: NSView) {
        webView.removeFromSuperview()
        // No constraints. The page's height must not enter the window's solver.
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.frame = container.bounds
        container.addSubview(webView)
    }

    final class Coordinator {
        let player: YouTubePlayer
        init(_ player: YouTubePlayer) { self.player = player }
    }
}

/// Holds the page while the grid is on screen, so playback is not torn down
/// and the watch page is not part of the window's constraint loop.
enum PlaybackParking {
    static var retainKey: UInt8 = 0
    private static let host = NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 9))

    static func hold(_ webView: WKWebView) {
        webView.removeFromSuperview()
        webView.frame = host.bounds
        host.addSubview(webView)
    }
}

/// Keeps the YouTube document's size from resizing the player.
private final class PlayerHostView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func invalidateIntrinsicContentSize() {}

    override func layout() {
        super.layout()
        for subview in subviews { subview.frame = bounds }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
