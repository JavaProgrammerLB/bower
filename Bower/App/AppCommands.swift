import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Playlist, Channel, or Video…") { model.activeSheet = .add }
                .keyboardShortcut("n")
            Button("New Folder") { model.store.createFolder(named: "New Folder") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .importExport) {
            Button("Import Library…") { model.importLibrary() }
            Button("Export Library…") { model.exportLibrary() }
        }

        CommandGroup(after: .sidebar) {
            Button(model.showVideoList ? "Hide Video List" : "Show Video List") {
                model.showVideoList.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }

        CommandMenu("Library") {
            Button("Search Videos…") { model.activeSheet = .search }
                .keyboardShortcut("k")
            Divider()
            Button("Check for New Videos") { model.library.refreshAll(full: false) }
                .keyboardShortcut("r")
                .disabled(model.library.isRefreshing)
            Button("Reload Everything") { model.library.refreshAll(full: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.library.isRefreshing)
            Divider()
            Button("Latest") { model.selection = .latest }
                .keyboardShortcut("1")
            Button("Bookmarks") { model.selection = .bookmarks }
                .keyboardShortcut("2")
            Button("History") { model.selection = .history }
                .keyboardShortcut("3")
            Divider()
            Button("Clear Watch History") { model.store.clearHistory() }
                .disabled(model.store.watchHistory.isEmpty)
            Divider()
            Button("YouTube Account…") { model.activeSheet = .cookie }
        }

        CommandMenu("Playback") {
            let playback = model.playback
            Button(playback.player.isPlaying ? "Pause" : "Play") { playback.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Next Video") { playback.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!playback.canGoNext)
            Button("Previous Video") { playback.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(playback.current == nil)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { playback.shuffle }, set: { playback.shuffle = $0 }))
            Picker("Repeat", selection: Binding(get: { playback.loopMode }, set: { playback.loopMode = $0 })) {
                Text("Off").tag(LoopMode.off)
                Text("All").tag(LoopMode.all)
                Text("One").tag(LoopMode.one)
            }
            Divider()
            Button(playback.current.map { model.store.isBookmarked($0.id) } == true ? "Remove Bookmark" : "Bookmark") {
                if let video = playback.current { model.store.toggleBookmark(video) }
            }
            .keyboardShortcut("d")
            .disabled(playback.current == nil)
            Button("Open in YouTube") {
                if let video = playback.current { NSWorkspace.shared.open(video.watchURL) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(playback.current == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Toggle("Float on Top", isOn: $alwaysOnTop)
                .keyboardShortcut("t", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .help) {
            Button("Give Feedback") {
                NSWorkspace.shared.open(URL(string: "mailto:support@limstack.com")!)
            }
        }
    }
}
