import AppKit
import SwiftUI

// MARK: - Add

struct AddSourceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isWorking = false
    @State private var error: String?

    private var kind: YouTubeURL.Kind? { YouTubeURL.classify(text) }

    private var kindLabel: (String, String)? {
        switch kind {
        case .playlist: ("Playlist", "list.and.film")
        case .channel: ("Channel", "person.crop.circle")
        case .video: ("Video — added to Bookmarks", "play.rectangle")
        case .unsupported(let reason): (reason, "exclamationmark.triangle")
        case nil: nil
        }
    }

    private var canAdd: Bool {
        switch kind {
        case .playlist, .channel, .video: !isWorking
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add from YouTube")
                    .font(.title3.weight(.semibold))
                Text("Paste a link to a playlist, a channel, or a single video.")
                    .foregroundStyle(.secondary)
            }

            // Verbatim: as a LocalizedStringKey the URL would be parsed as a
            // Markdown link and drawn in the link color.
            TextField("URL", text: $text, prompt: Text(verbatim: "https://www.youtube.com/@channel"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .disabled(isWorking)
                .onSubmit { if canAdd { add() } }
                .onChange(of: text) { error = nil }

            HStack(alignment: .firstTextBaseline) {
                Group {
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    } else if isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Fetching videos…")
                        }
                        .foregroundStyle(.secondary)
                    } else if let (label, icon) = kindLabel {
                        Label(label, systemImage: icon)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            // Offer a YouTube link that is already on the clipboard.
            if let clip = NSPasteboard.general.string(forType: .string), YouTubeURL.classify(clip) != nil, clip.count < 500 {
                text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func add() {
        isWorking = true
        error = nil
        Task {
            do {
                let added = try await app.library.add(text)
                dismiss()
                if let videoID = added.videoID {
                    app.reveal(videoID, in: added.selection)
                } else {
                    app.selection = added.selection
                }
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Cookie

struct CookieSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var hasSaved = CookieStore.shared.hasCookie
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, busy
        case ok(String)
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("YouTube Account")
                    .font(.title3.weight(.semibold))
                Text("Signs library requests and the video player in as your account, so YouTube stops treating Bower as a bot. Paste the `cookie` header from a signed-in youtube.com request, or the contents of a cookies.txt export.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $input)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .frame(height: 120)
                .disabled(status == .busy)
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text(hasSaved ? "Paste a new cookie to replace the saved one" : "SID=…; SAPISID=…; …")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(11)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: input) { if status != .busy { status = .idle } }

            HStack(alignment: .firstTextBaseline) {
                statusView
                Spacer()
                if hasSaved {
                    Button("Remove") { remove() }
                        .disabled(status == .busy)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(status == .busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("These cookies give full access to your Google account. They are kept in this app's data folder and only ever sent to YouTube. While one is saved, watching here counts towards your account's history and recommendations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Text(hasSaved ? "A cookie is saved." : "No cookie saved — requests are anonymous.")
                .foregroundStyle(.secondary)
        case .busy:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking with YouTube…").foregroundStyle(.secondary)
            }
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func save() {
        let parsed = ParsedCookie(input: input)
        guard !parsed.cookie.isEmpty else {
            status = .error("No cookies found in that text.")
            return
        }
        guard parsed.hasSAPISID else {
            status = .error("Missing SAPISID — copy it from a signed-in youtube.com tab, including secure cookies.")
            return
        }
        status = .busy
        CookieStore.shared.set(parsed.cookie)
        hasSaved = true
        input = ""
        Task {
            await CookieStore.shared.syncToWebKit(clearExisting: true)
            app.playback.player.reload()
            let result = await InnerTubeClient.shared.verifySignedIn()
            if result.signedIn {
                status = .ok(result.accountName.map { "Signed in as \($0)." } ?? "Cookie accepted by YouTube.")
            } else {
                status = .error("Saved, but YouTube didn't accept it\(result.detail.map { " — \($0)" } ?? ""). If it expired, sign in again and re-copy.")
            }
        }
    }

    private func remove() {
        CookieStore.shared.set("")
        hasSaved = false
        input = ""
        status = .ok("Cookie removed. Requests and playback are anonymous again.")
        Task {
            await CookieStore.shared.syncToWebKit(clearExisting: true)
            app.playback.player.reload()
        }
    }
}

// MARK: - Search

private struct SearchResult: Identifiable {
    var video: Video
    var selection: LibrarySelection
    var sourceTitle: String
    var icon: String
    var id: String { "\(video.id)-\(sourceTitle)" }
}

/// Searches every video in the library (⌘K).
struct SearchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index: [SearchResult] = []
    @State private var highlighted: String?
    @FocusState private var fieldFocused: Bool
    @State private var sheetWindow: NSWindow?
    @State private var clickMonitor: Any?

    private var results: [SearchResult] {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return [] }
        var hits: [SearchResult] = []
        for item in index {
            let haystack = "\(item.video.title) \(item.sourceTitle)".lowercased()
            if terms.allSatisfy({ haystack.contains($0) }) {
                hits.append(item)
                if hits.count == 60 { break }
            }
        }
        return hits
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                TextField("Search videos in your library", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { if let pick = results.first(where: { $0.id == highlighted }) ?? results.first { open(pick) } }
                    .onKeyPress(.downArrow) { moveHighlight(1, in: results); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1, in: results); return .handled }
                    .onChange(of: query) { highlighted = self.results.first?.id }
            }
            .padding(16)

            if !query.isEmpty {
                Divider()
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(height: 220)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(results) { result in
                                    resultRow(result)
                                        .id(result.id)
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 380)
                        .onChange(of: highlighted) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
            }
        }
        .frame(width: 600)
        .background(WindowAccessor { sheetWindow = $0 })
        .onAppear {
            buildIndex()
            fieldFocused = true
            installClickMonitor()
        }
        .onDisappear {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
        .onExitCommand { dismiss() }
    }

    /// The sheet blocks the window behind it, so clicks there never reach
    /// SwiftUI; catch them here and treat them as a dismiss.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let sheetWindow, event.window !== sheetWindow,
                  event.window === sheetWindow.sheetParent else { return event }
            dismiss()
            return nil
        }
    }

    private func resultRow(_ result: SearchResult) -> some View {
        HStack(spacing: 10) {
            RemoteImage(url: result.video.thumbnail)
                .frame(width: 72, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.video.title)
                    .lineLimit(1)
                Label(result.sourceTitle, systemImage: result.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(result.video.duration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(6)
        .background(result.id == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = result.id } }
        .onTapGesture { open(result) }
    }

    private func moveHighlight(_ delta: Int, in results: [SearchResult]) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == highlighted } ?? -1
        let next = min(max(current + delta, 0), results.count - 1)
        highlighted = results[next].id
    }

    private func buildIndex() {
        let store = app.store
        var seen = Set<String>()
        var items: [SearchResult] = []
        for (kind, sources) in [(SourceKind.playlist, store.playlists), (.channel, store.channels)] {
            for source in sources {
                for video in source.items where seen.insert(video.id).inserted {
                    items.append(SearchResult(video: video, selection: LibrarySelection(SourceRef(type: kind, id: source.id)),
                                              sourceTitle: source.title,
                                              icon: kind == .playlist ? "list.and.film" : "person.crop.circle"))
                }
            }
        }
        for video in store.videos(for: .bookmarks) where seen.insert(video.id).inserted {
            items.append(SearchResult(video: video, selection: .bookmarks, sourceTitle: "Bookmarks", icon: "bookmark"))
        }
        index = items
    }

    private func open(_ result: SearchResult) {
        dismiss()
        app.reveal(result.video.id, in: result.selection)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("theme") private var theme: Theme = .system
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Keep window on top of other apps", isOn: $alwaysOnTop)
            }

            Section("YouTube Account") {
                LabeledContent("Cookie") {
                    Text(CookieStore.shared.hasCookie ? "Saved" : "Not set")
                        .foregroundStyle(.secondary)
                }
                Button("Edit YouTube Account…") { app.activeSheet = .cookie }
            }

            Section("Library") {
                LabeledContent("Sources", value: "\(app.store.playlists.count) playlists, \(app.store.channels.count) channels")
                HStack {
                    Button("Import…") { app.importLibrary() }
                    Button("Export…") { app.exportLibrary() }
                    Spacer()
                    Button("Show Data Folder") { NSWorkspace.shared.open(AppPaths.dataDirectory) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
