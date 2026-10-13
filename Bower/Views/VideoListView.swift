import AppKit
import QuartzCore
import SwiftUI

/// The right-hand list of videos for whatever the sidebar has selected.
struct VideoListView: View {
    @Environment(AppModel.self) private var app
    @State private var isScrolled = false

    var body: some View {
        let videos = app.filteredVideos
        let playingHere = app.playback.queueContext == app.selection
        let currentID = playingHere ? app.playback.current?.id : nil

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
            .contentMargins(.top, 10, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(isScrolled ? .hard : .automatic, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 0.5
            } action: { _, isScrolled in
                self.isScrolled = isScrolled
            }
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
        .onDisappear { app.filter = "" }
    }

    /// Single-source lists don't need every row to repeat the source name.
    private var showsSource: Bool {
        switch app.selection {
        case .playlist, .channel: false
        default: true
        }
    }
}

/// The inspector title and playback position, above the toolbar material.
struct VideoListHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let count = app.displayedVideos.count
        let currentID = app.playback.queueContext == app.selection ? app.playback.current?.id : nil

        VStack(alignment: .leading, spacing: 1) {
            Text(app.displayedTitle)
                .font(.headline)
                .lineLimit(1)
            Text(positionText(count: count, currentID: currentID))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func positionText(count: Int, currentID: String?) -> String {
        let noun = count == 1 ? "video" : "videos"
        guard let currentID, let index = app.displayedVideos.firstIndex(where: { $0.id == currentID }) else {
            return "\(count) \(noun)"
        }
        return "\(index + 1) of \(count) \(noun)"
    }
}

/// Place the title above the inspector material, inside its native split pane,
/// so it inherits the pane's opening and closing animation.
struct InspectorHeaderAnchor: NSViewRepresentable {
    @Environment(AppModel.self) private var app

    private var header: AnyView {
        AnyView(VideoListHeader()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .environment(app))
    }

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(header: header)
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.header.rootView = header
        view.updateHeader()
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.detach()
    }

    final class AnchorView: NSView {
        let header: NSHostingView<AnyView>
        private let overlay = HeaderOverlay()
        private var ancestors: [ObservedView] = []

        init(header: AnyView) {
            self.header = NSHostingView(rootView: header)
            super.init(frame: .zero)
            self.header.sizingOptions = []
            self.header.safeAreaRegions = []
            self.header.sceneBridgingOptions = []
            overlay.clipsToBounds = true
            overlay.addSubview(self.header)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            var column: NSView? = self
            while let view = column, !(view.superview is NSSplitView) {
                column = view.superview
            }
            guard let column, column.superview is NSSplitView else { return }
            column.addSubview(overlay, positioned: .above, relativeTo: nil)
            var ancestor: NSView? = self
            while let view = ancestor {
                ancestors.append(ObservedView(view))
                view.postsFrameChangedNotifications = true
                ancestor = view.superview
            }
            NotificationCenter.default.addObserver(self, selector: #selector(frameChanged(_:)),
                                                   name: NSView.frameDidChangeNotification, object: nil)
            updateHeader()
        }

        @objc private func frameChanged(_ notification: Notification) {
            guard let view = notification.object as? NSView,
                  ancestors.contains(where: { $0.view === view }) else { return }
            updateHeader()
        }

        func updateHeader() {
            guard let window, let column = overlay.superview,
                  let frameView = window.contentView?.superview else {
                overlay.isHidden = true
                return
            }
            let sidebar = column.convert(column.bounds, to: nil)
            let windowBounds = frameView.convert(frameView.bounds, to: nil)
            guard sidebar.width > 0, sidebar.maxX >= windowBounds.maxX - 1 else {
                overlay.isHidden = true
                return
            }
            let top = window.contentLayoutRect.maxY
            let toolbar = NSRect(x: sidebar.minX, y: top, width: sidebar.width,
                                 height: max(0, windowBounds.maxY - top))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let overlayFrame = column.convert(toolbar, from: nil)
            let headerFrame = NSRect(x: 10, y: 0, width: max(0, sidebar.width - 110), height: toolbar.height)
            if overlay.frame != overlayFrame { overlay.frame = overlayFrame }
            if header.frame != headerFrame { header.frame = headerFrame }
            overlay.isHidden = sidebar.width <= 0 || toolbar.height <= 0
            CATransaction.commit()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            for ancestor in ancestors {
                ancestor.view?.postsFrameChangedNotifications = ancestor.wasPosting
            }
            ancestors = []
            overlay.removeFromSuperview()
        }

        private final class ObservedView {
            weak var view: NSView?
            let wasPosting: Bool
            init(_ view: NSView) {
                self.view = view
                wasPosting = view.postsFrameChangedNotifications
            }
        }

        private final class HeaderOverlay: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
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

/// Narrows the video list; pinned to the bottom of the right sidebar.
private struct FilterBar: View {
    @Environment(AppModel.self) private var app
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 6) {
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
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 6)
    }
}
