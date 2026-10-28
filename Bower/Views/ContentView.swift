import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            ZStack {
                // Kept in the window while hidden so playback carries on
                // while browsing the grid.
                NowPlayingView()
                    .opacity(app.isPlayerVisible ? 1 : 0)
                    .allowsHitTesting(app.isPlayerVisible)
                    .accessibilityHidden(!app.isPlayerVisible)
                if !app.isPlayerVisible {
                    VideoGridView()
                }
            }
            .toolbar {
                if app.isPlayerVisible {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { app.isPlayerVisible = false }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .help("Back to \(app.displayedTitle)")
                        .keyboardShortcut("[", modifiers: .command)
                    }
                }
            }
        }
        // On the split view rather than the detail column, so the list is
        // always a full-height trailing column; on the detail column it came
        // back under a window-wide toolbar after being toggled.
        .inspector(isPresented: Binding(get: { app.isPlayerVisible && app.showVideoList },
                                        // Leaving the player dismisses the inspector too;
                                        // that must not count as the user hiding the list.
                                        set: { if app.isPlayerVisible { app.showVideoList = $0 } })) {
            VideoListView()
                .inspectorColumnWidth(min: 280, ideal: 340, max: 560)
                .background(InspectorHeaderAnchor())
                .toolbar {
                    if #available(macOS 26.0, *) {
                        ToolbarSpacer(.flexible)
                        ToolbarItem(placement: .automatic) {
                            toolbarControls
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .primaryAction) {
                            toolbarControls
                        }
                    }
                }
        }
        .navigationTitle(app.displayedTitle)
        .sheet(item: $app.activeSheet) { sheet in
            switch sheet {
            case .add: AddSourceSheet()
            case .cookie: CookieSheet()
            case .search: SearchSheet()
            }
        }
        .alert("Bower", isPresented: Binding(get: { app.alertMessage != nil }, set: { if !$0 { app.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(app.alertMessage ?? "")
        }
        .alert(
            refreshFailureTitle,
            isPresented: Binding(get: { !app.library.isRefreshing && !app.library.failures.isEmpty },
                                 set: { if !$0 { app.library.failures = [] } })
        ) {
            Button("OK") {}
        } message: {
            Text(app.library.failures.prefix(6).map { "\($0.title): \($0.message)" }.joined(separator: "\n"))
        }
        .onChange(of: app.store.contentRevision) { app.libraryChanged() }
        .onChange(of: app.store.userRevision) { app.userDataChanged() }
        .onChange(of: activeState) { _, state in
            if state == .key { app.library.refreshIfStale() }
        }
        .task { app.library.refreshIfStale() }
        .background(WindowAccessor { window in
            window.level = alwaysOnTop ? .floating : .normal
        }.id(alwaysOnTop))
    }

    // One persistent group stays at the trailing edge as the inspector toggles.
    private var toolbarControls: some View {
        HStack(spacing: 2) {
            if !app.isPlayerVisible, app.playback.current != nil {
                toolbarButton("Now Playing",
                              systemImage: app.playback.player.isPlaying ? "waveform" : "play.rectangle",
                              help: "Show Now Playing") {
                    withAnimation(.snappy(duration: 0.25)) { app.showPlayer() }
                }
            }
            toolbarButton("Search", systemImage: "magnifyingglass", help: "Search Videos (⌘K)") {
                app.activeSheet = .search
            }
            if app.isPlayerVisible {
                toolbarButton("Video List", systemImage: "sidebar.trailing",
                              help: app.showVideoList ? "Hide Video List" : "Show Video List") {
                    app.showVideoList.toggle()
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
        .modifier(CapsuleGlass())
    }

    private func toolbarButton(_ title: String, systemImage: String, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 32)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(help)
    }

    private var refreshFailureTitle: String {
        let count = app.library.failures.count
        return "Couldn't update \(count) \(count == 1 ? "source" : "sources")"
    }
}

/// Hands the hosting NSWindow to a closure once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
    }
}
