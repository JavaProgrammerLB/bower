import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ActiveSheet: String, Identifiable {
    case add, cookie, search
    var id: String { rawValue }
}

@Observable
final class AppModel {
    let store: LibraryStore
    let playback: PlaybackModel
    let library: LibraryService

    var selection: LibrarySelection? = .latest {
        didSet {
            guard selection != oldValue else { return }
            reloadDisplayed()
            isPlayerVisible = false
            filter = ""
        }
    }

    /// Narrows the visible list (grid and video list alike).
    var filter = "" {
        didSet { if filter != oldValue { applyFilter() } }
    }

    private(set) var filteredVideos: [Video] = []

    /// Lowercased title + source per displayed video, built on first use of
    /// the filter so typing doesn't redo it for every video on each key.
    @ObservationIgnored private var haystacks: [String]?

    /// The main area shows either the selected list as a grid of videos or,
    /// once a video is picked, the player with the list alongside it.
    var isPlayerVisible = false

    private(set) var displayedVideos: [Video] = []

    var showVideoList: Bool = UserDefaults.standard.object(forKey: "showVideoList") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showVideoList, forKey: "showVideoList") }
    }

    var activeSheet: ActiveSheet?
    var alertMessage: String?

    init() {
        let store = LibraryStore()
        self.store = store
        playback = PlaybackModel(store: store)
        library = LibraryService(store: store)
        reloadDisplayed()
        Task { await CookieStore.shared.syncToWebKit(clearExisting: false) }
    }

    var displayedTitle: String {
        selection.map { store.title(for: $0) } ?? "Bower"
    }

    func reloadDisplayed() {
        displayedVideos = selection.map { store.videos(for: $0) } ?? []
        haystacks = nil
        applyFilter()
    }

    private func applyFilter() {
        let terms = filter.lowercased().split(separator: " ")
        guard !terms.isEmpty else {
            filteredVideos = displayedVideos
            return
        }
        let haystacks = haystacks ?? displayedVideos.map { "\($0.title) \($0.sourceTitle ?? "")".lowercased() }
        self.haystacks = haystacks
        filteredVideos = zip(displayedVideos, haystacks).compactMap { video, haystack in
            terms.allSatisfy { haystack.contains($0) } ? video : nil
        }
    }

    /// Sources' videos changed underneath: rebuild what is shown and the queue.
    func libraryChanged() {
        reloadDisplayed()
        if let selection, store.isMissing(selection) {
            self.selection = .latest
            return
        }
        if let context = playback.queueContext {
            let list = context == selection ? displayedVideos : store.videos(for: context)
            playback.libraryChanged(list, context: context)
        }
    }

    /// Bookmarks or history changed: only those two lists depend on them.
    func userDataChanged() {
        let dependent: Set<LibrarySelection> = [.bookmarks, .history]
        if let selection, dependent.contains(selection) { reloadDisplayed() }
        if let context = playback.queueContext, dependent.contains(context) {
            let list = context == selection ? displayedVideos : store.videos(for: context)
            playback.libraryChanged(list, context: context)
        }
    }

    func play(_ video: Video) {
        guard let selection else { return }
        playback.play(video, from: displayedVideos, context: selection)
        isPlayerVisible = true
    }

    /// Plays the visible list from the top (or from a random video when
    /// shuffling), skipping hidden videos.
    func playAll() {
        let playable = displayedVideos.filter { !store.isSkipped($0.id) }
        guard let first = playback.shuffle ? playable.randomElement() : playable.first else { return }
        play(first)
    }

    func showPlayer() {
        guard playback.current != nil else { return }
        if let context = playback.queueContext, context != selection {
            selection = context
        }
        isPlayerVisible = true
    }

    /// Shows `selection` with one of its videos cued, as when picking a
    /// search result.
    func reveal(_ videoID: String, in selection: LibrarySelection) {
        self.selection = selection
        if let video = displayedVideos.first(where: { $0.id == videoID }) {
            playback.play(video, from: displayedVideos, context: selection, autoplay: false)
            isPlayerVisible = true
        }
    }

    func deleteSource(_ ref: SourceRef) {
        store.remove(ref)
    }

    // MARK: Import / export

    func exportLibrary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "bower-export.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url, options: .atomic)
        } catch {
            alertMessage = "Couldn't export the library: \(error.localizedDescription)"
        }
    }

    func importLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try store.importData(Data(contentsOf: url))
            alertMessage = added == 1 ? "Imported 1 playlist or channel." : "Imported \(added) playlists and channels."
        } catch {
            alertMessage = "That file isn't a Bower export."
        }
    }

    func flush() {
        playback.flush()
        store.flush()
    }
}

extension LibraryStore {
    func isMissing(_ selection: LibrarySelection) -> Bool {
        switch selection {
        case .latest, .bookmarks, .history: false
        case .folder(let id): folder(id) == nil
        case .playlist, .channel: selection.sourceRef.map { source($0) == nil } ?? true
        }
    }
}
