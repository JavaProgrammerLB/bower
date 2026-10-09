import AppKit
import SwiftUI

struct NowPlayingView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        Group {
            if let video = playback.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PlayerSurface(player: playback.player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

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

/// Hosts the player's single WKWebView. SwiftUI may rebuild this container;
/// the web view itself (and whatever is playing) survives.
struct PlayerSurface: NSViewRepresentable {
    let player: YouTubePlayer

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if player.webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let webView = player.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
