import AppKit
import SwiftUI

/// The right-hand list of videos for whatever the sidebar has selected.
struct VideoListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let videos = app.filteredVideos
        let playingHere = app.playback.queueContext == app.selection
        let currentID = playingHere ? app.playback.current?.id : nil

        VStack(spacing: 0) {
            header(count: app.displayedVideos.count, currentID: currentID)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(videos) { video in
                        VideoRow(video: video, isCurrent: video.id == currentID,
                                 isPlaying: video.id == currentID && app.playback.player.isPlaying,
                                 showsSource: showsSource)
                            .id(video.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    }
                }
                .listStyle(.plain)
                .safeAreaPadding(.top, 10)
                .scrollContentBackground(.hidden)
                .overlay {
                    if videos.isEmpty && !app.filter.isEmpty {
                        ContentUnavailableView.search(text: app.filter)
                    }
                }
                .onChange(of: currentID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let currentID { proxy.scrollTo(currentID, anchor: .center) }
                }
                .safeAreaBar(edge: .bottom) { FilterBar() }
            }
        }
        .onDisappear { app.filter = "" }
    }

    /// Single-source lists don't need every row to repeat the source name.
    private var showsSource: Bool {
        switch app.selection {
        case .playlist, .channel: false
        default: true
        }
    }

    private func header(count: Int, currentID: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayedTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(positionText(count: count, currentID: currentID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if app.selection == .history {
                Button("Clear") { app.store.clearHistory() }
                    .controlSize(.small)
                    .disabled(app.store.watchHistory.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func positionText(count: Int, currentID: String?) -> String {
        let noun = count == 1 ? "video" : "videos"
        guard let currentID, let index = app.displayedVideos.firstIndex(where: { $0.id == currentID }) else {
            return "\(count) \(noun)"
        }
        return "\(index + 1) of \(count) \(noun)"
    }
}

struct VideoRow: View {
    @Environment(AppModel.self) private var app
    let video: Video
    let isCurrent: Bool
    let isPlaying: Bool
    let showsSource: Bool

    @State private var isHovering = false

    var body: some View {
        let isSkipped = app.store.isSkipped(video.id)
        let isBookmarked = app.store.isBookmarked(video.id)

        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: video.thumbnail)
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(video.duration)
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
                if isCurrent {
                    Image(systemName: isPlaying ? "waveform" : "pause.fill")
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 112, height: 63)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // As tall as the thumbnail, with the metadata row pinned to its
            // bottom edge. The row has a fixed height, so the buttons that
            // appear on hover never shift the layout.
            VStack(alignment: .leading, spacing: 0) {
                Text(video.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 2)
                HStack(spacing: 2) {
                    Text(meta)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    actionButtons(isSkipped: isSkipped, isBookmarked: isBookmarked)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 18)
            }
            .frame(height: 63)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.16) : isHovering ? Color.primary.opacity(0.05) : .clear)
        }
        .opacity(isSkipped ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if isCurrent {
                if !isPlaying { app.playback.togglePlayPause() }
            } else {
                app.play(video)
            }
        }
        .contextMenu { VideoContextMenu(video: video) }
    }

    private var meta: String {
        var parts: [String] = []
        if let date = video.publishedDate { parts.append(RelativeTime.format(date)) }
        if showsSource, let source = video.sourceTitle { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actionButtons(isSkipped: Bool, isBookmarked: Bool) -> some View {
        if isSkipped {
            rowButton("eye", help: "Show — include this video in playback again") {
                app.store.setSkipped(video.id, false)
            }
        } else {
            if isHovering {
                rowButton("eye.slash", help: "Hide — skip this video during playback") {
                    app.playback.hide(video)
                }
            }
            if isHovering || isBookmarked {
                rowButton(isBookmarked ? "bookmark.fill" : "bookmark",
                          tint: isBookmarked ? .accentColor : nil,
                          help: isBookmarked ? "Remove Bookmark" : "Bookmark") {
                    app.store.toggleBookmark(video)
                }
            }
        }
    }

    private func rowButton(_ symbol: String, tint: Color? = nil, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Pinned to the bottom of the right sidebar: the filter field, plus
/// shuffle and repeat.
private struct FilterBar: View {
    @Environment(AppModel.self) private var app
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            filterField
            HStack(spacing: 0) {
                PlaybackModeButtons()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 6)
    }

    private var filterField: some View {
        @Bindable var app = app
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $app.filter)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand {
                    app.filter = ""
                    isFocused = false
                }
            if !app.filter.isEmpty {
                Button {
                    app.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Filter")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Shuffle and repeat, which apply to the queue being played.
private struct PlaybackModeButtons: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        Button {
            playback.shuffle.toggle()
        } label: {
            Image(systemName: "shuffle")
                .foregroundStyle(playback.shuffle ? Color.accentColor : .secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .help(playback.shuffle ? "Shuffle: On" : "Shuffle: Off")

        Button {
            playback.loopMode = playback.loopMode.next
        } label: {
            Image(systemName: playback.loopMode == .one ? "repeat.1" : "repeat")
                .foregroundStyle(playback.loopMode == .off ? Color.secondary : Color.accentColor)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .help(repeatHelp(playback.loopMode))
    }

    private func repeatHelp(_ mode: LoopMode) -> String {
        switch mode {
        case .off: "Repeat: Off"
        case .all: "Repeat: All"
        case .one: "Repeat: One"
        }
    }
}
