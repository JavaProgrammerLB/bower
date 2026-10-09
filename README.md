# Bower

A native macOS 26 app (SwiftUI + AppKit) for following YouTube playlists and channels
without the algorithm.

## Build

```sh
xcodegen generate          # regenerates Bower.xcodeproj from project.yml
open Bower.xcodeproj
```

## Layout

- `App/` — entry point, menu commands, `AppModel` (selection, sheets, import/export)
- `Models/` — Codable models
- `Store/` — `LibraryStore` (library, folders, bookmarks, history, hidden videos), resume positions, description cache
- `YouTube/` — a small InnerTube client, URL classification, cookie handling
- `Services/` — refresh/add logic, image + avatar caching
- `Player/` — `YouTubePlayer` (iframe API inside one persistent WKWebView) and `PlaybackModel` (queue, shuffle, repeat)
- `Views/` — sidebar, now-playing pane, video list inspector, sheets, settings

Data lives in `~/Library/Application Support/me.limboy.Bower/`.
