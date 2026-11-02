import AppKit
import Observation
import WebKit

/// Drives playback inside one long-lived WKWebView. Cueing still uses the
/// iframe API. Playing loads a YouTube document so the saved account cookie
/// is first-party and the embed request carries a Referer — a bare embed
/// navigation is rejected with error 153, and the localhost setup page makes
/// the player a third-party document that drops the cookie.
@Observable
final class YouTubePlayer: NSObject {
    enum State: Int {
        case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3, cued = 5
    }

    private(set) var state: State = .unstarted
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var errorMessage: String?
    private(set) var isReady = false

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored var onStartedPlaying: (() -> Void)?
    @ObservationIgnored var onProgress: ((Double, Double) -> Void)?

    private enum PageKind { case setup, embed, watch }

    @ObservationIgnored private var pendingLoad: (id: String, start: Double, autoplay: Bool)?
    @ObservationIgnored private var currentVideoID: String?
    @ObservationIgnored private var reportedPlaying = false
    @ObservationIgnored private var pageKind: PageKind = .setup
    @ObservationIgnored private var pageVideoID: String?
    @ObservationIgnored private var fellBackToWatch = false
    @ObservationIgnored private var playGeneration = 0

    var isPlaying: Bool { state == .playing || state == .buffering }

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true
        let controller = WKUserContentController()
        config.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .black
        super.init()

        controller.add(WeakMessageHandler(self), name: "lt")
        controller.addUserScript(WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: Self.cookieDiagScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // #region agent log
        agentLog("H10", "YouTubePlayer.init", "cookie policy", [
            "policy": HTTPCookieStorage.shared.cookieAcceptPolicy.rawValue
        ])
        // #endregion
        loadPage()
    }

    /// The page's origin, which the embed sees as its embedder. YouTube rejects
    /// embedders it can't identify (error 152) but accepts http://localhost.
    /// The port is fixed so the origin stays the same across launches.
    private static let pageOrigin = URL(string: "http://localhost:17422/")!
    private static let youtubeOrigin = URL(string: "https://www.youtube.com/")!

    func loadPage() {
        isReady = false
        pageKind = .setup
        pageVideoID = nil
        fellBackToWatch = false
        webView.loadHTMLString(Self.html, baseURL: Self.pageOrigin)
    }

    /// Reloads the player so it picks up changed cookies.
    func reload() {
        if let id = currentVideoID {
            pendingLoad = (id, currentTime, false)
        }
        loadPage()
    }

    func load(videoID: String, startAt start: Double?, autoplay: Bool) {
        currentVideoID = videoID
        reportedPlaying = false
        errorMessage = nil
        let start = (start ?? 0).rounded(.down)
        currentTime = start
        if autoplay {
            play()
            return
        }
        guard isReady else {
            pendingLoad = (videoID, start, autoplay)
            return
        }
        call("ltLoad(\(Self.jsString(videoID)), \(start), \(autoplay))")
    }

    func play() {
        guard let id = currentVideoID else {
            // #region agent log
            agentLog("H4", "YouTubePlayer.play", "resume without video", ["pageKind": "\(pageKind)"])
            // #endregion
            send(.play)
            return
        }
        if pageVideoID == id, pageKind == .embed || pageKind == .watch {
            // #region agent log
            agentLog("H4", "YouTubePlayer.play", "already on page", ["pageKind": "\(pageKind)", "video": id])
            // #endregion
            send(.play)
            return
        }
        playGeneration += 1
        let generation = playGeneration
        let start = currentTime
        // #region agent log
        agentLog("H4", "YouTubePlayer.play", "navigate", ["generation": generation, "video": id, "pageKind": "\(pageKind)"])
        // #endregion
        Task { @MainActor in
            await CookieStore.shared.syncToWebKit(clearExisting: true)
            let stillCurrent = generation == self.playGeneration && self.currentVideoID == id
            // #region agent log
            agentLog("H4", "YouTubePlayer.play", "after sync", ["generation": generation, "stillCurrent": stillCurrent, "video": id])
            // #endregion
            guard stillCurrent else { return }
            // Embedding from this app is rejected (153 without a Referer, 152-4
            // when the document origin is youtube.com). The watch page is a
            // first-party youtube.com navigation, so it sends the account cookie.
            self.loadWatchPage(videoID: id, start: start)
            await self.probeNativePlayer(videoID: id)
        }
    }

    // #region agent log
    private func probeNativePlayer(videoID: String) async {
        guard let json = await InnerTubeClient.shared.playerDocument(videoID: videoID) as? [String: Any] else {
            agentLog("H40", "YouTubePlayer.nativeplayer", "player document", ["ok": false])
            return
        }
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? ""
        let reason = String((playability?["reason"] as? String ?? "").prefix(80))
        let details = json["videoDetails"] as? [String: Any]
        let streaming = json["streamingData"] as? [String: Any]
        let formats = streaming?["formats"] as? [[String: Any]] ?? []
        let adaptive = streaming?["adaptiveFormats"] as? [[String: Any]] ?? []
        let sabr = ((streaming?["serverAbrStreamingUrl"] as? String) ?? "").isEmpty == false
        var urlCount = 0
        var cipherCount = 0
        var chosen: String?
        var itag = 0
        var mime = ""
        for item in formats + adaptive {
            if item["signatureCipher"] != nil || item["cipher"] != nil { cipherCount += 1 }
            guard let media = item["url"] as? String, !media.isEmpty else { continue }
            urlCount += 1
            let itemMime = item["mimeType"] as? String ?? ""
            if chosen == nil, itemMime.hasPrefix("video/mp4"), itemMime.contains("mp4a") {
                chosen = media
                itag = item["itag"] as? Int ?? (item["itag"] as? Double).map(Int.init) ?? 0
                mime = String(itemMime.prefix(48))
            }
        }
        agentLog("H40", "YouTubePlayer.nativeplayer", "player document", [
            "ok": true,
            "status": status,
            "reason": reason,
            "videoMatch": (details?["videoId"] as? String) == videoID,
            "sabr": sabr,
            "formats": formats.count,
            "adaptive": adaptive.count,
            "urlCount": urlCount,
            "cipherCount": cipherCount,
            "itag": itag,
            "mime": mime,
            "hasN": chosen?.contains("n=") == true,
            "hasURL": chosen != nil,
        ])
        guard let chosen, let mediaURL = URL(string: chosen) else { return }
        await probeMedia(mediaURL, via: "native-api")
    }

    private func probeMedia(_ mediaURL: URL, via: String) async {
        var head = URLRequest(url: mediaURL)
        head.httpMethod = "HEAD"
        head.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        head.setValue(InnerTubeClient.userAgent, forHTTPHeaderField: "User-Agent")
        let headResult = try? await URLSession.shared.data(for: head)
        let headHTTP = headResult?.1 as? HTTPURLResponse
        var ranged = URLRequest(url: mediaURL)
        ranged.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        ranged.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        ranged.setValue(InnerTubeClient.userAgent, forHTTPHeaderField: "User-Agent")
        let rangedResult = try? await URLSession.shared.data(for: ranged)
        let rangedHTTP = rangedResult?.1 as? HTTPURLResponse
        let bytes = rangedResult?.0 ?? Data()
        let note: String = {
            guard bytes.count > 0, bytes.count < 80, let text = String(data: bytes, encoding: .utf8),
                  !text.contains("http"), !text.contains("googlevideo") else { return "" }
            return text
        }()
        agentLog("H39", "YouTubePlayer.nativeplayer", "media response", [
            "via": via,
            "head": headHTTP?.statusCode ?? 0,
            "range": rangedHTTP?.statusCode ?? 0,
            "mime": rangedHTTP?.value(forHTTPHeaderField: "Content-Type") ?? headHTTP?.value(forHTTPHeaderField: "Content-Type") ?? "",
            "bytes": bytes.count,
            "ftyp": bytes.range(of: Data("ftyp".utf8)) != nil,
            "note": note,
        ])
    }
    // #endregion

    func pause() { send(.pause) }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        send(.seek(seconds))
    }

    func restart() {
        reportedPlaying = false
        send(.seek(0))
    }

    func stop() {
        currentVideoID = nil
        pageVideoID = nil
        send(.pause)
        call("player && player.stopVideo()")
    }

    /// Embed served as a youtube.com document, so the account cookie rides
    /// along and the iframe's Referer satisfies YouTube's player check.
    private func loadSignedInEmbed(videoID: String, start: Double) {
        pageKind = .embed
        pageVideoID = videoID
        fellBackToWatch = false
        webView.loadHTMLString(embedPage(videoID: videoID, start: start), baseURL: Self.youtubeOrigin)
    }

    /// The real watch page. Used when the embed still rejects its configuration,
    /// because a top-level youtube.com navigation always sends the stored cookie.
    private func loadWatchPage(videoID: String, start: Double) {
        guard let url = watchURL(videoID: videoID, start: start) else { return }
        pageKind = .watch
        pageVideoID = videoID
        webView.load(URLRequest(url: url))
    }

    private func embedPage(videoID: String, start: Double) -> String {
        var items = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "origin", value: "https://www.youtube.com"),
        ]
        if start > 1 {
            items.append(URLQueryItem(name: "start", value: String(Int(start.rounded(.down)))))
        }
        var components = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")
        components?.queryItems = items
        let src = (components?.url?.absoluteString ?? "").replacingOccurrences(of: "&", with: "&amp;")
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>
          html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
          iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
        </style>
        </head>
        <body>
        <iframe src="\(src)" referrerpolicy="strict-origin-when-cross-origin"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
        </body>
        </html>
        """
    }

    private func watchURL(videoID: String, start: Double) -> URL? {
        var items = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "autoplay", value: "1"),
        ]
        if start > 1 {
            items.append(URLQueryItem(name: "t", value: "\(Int(start.rounded(.down)))s"))
        }
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = items
        return components?.url
    }

    private enum Command {
        case play, pause, seek(Double)
    }

    /// The bridge script owns the media element, including one inside a
    /// cross-origin embed frame. The iframe API covers the setup page.
    private func send(_ command: Command) {
        let message: String
        switch command {
        case .play:
            message = "{source:'bower',cmd:'play'}"
        case .pause:
            message = "{source:'bower',cmd:'pause'}"
        case .seek(let seconds):
            message = "{source:'bower',cmd:'seek',time:\(seconds)}"
        }
        call("""
        (function(){
          var message = \(message);
          window.postMessage(message, '*');
          var frames = document.querySelectorAll('iframe');
          for (var i = 0; i < frames.length; i++) {
            try { frames[i].contentWindow.postMessage(message, '*'); } catch (e) {}
          }
          if (!window.player) return;
          if (message.cmd === 'pause' && player.pauseVideo) player.pauseVideo();
          else if (message.cmd === 'seek' && player.seekTo) { player.seekTo(message.time, true); player.playVideo(); }
          else if (player.playVideo) player.playVideo();
        })()
        """)
    }

    /// Embed error 152/153, or the bot interstitial the script reports as 1503.
    private func shouldLeaveEmbed(_ code: Int, videoID: String?) -> Bool {
        guard pageKind == .embed, !fellBackToWatch else { return false }
        guard code == 152 || code == 153 || code == 1503 else { return false }
        if let videoID, !videoID.isEmpty, videoID != currentVideoID { return false }
        guard let id = currentVideoID else { return false }
        fellBackToWatch = true
        errorMessage = nil
        loadWatchPage(videoID: id, start: currentTime)
        return true
    }

    private func call(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    fileprivate func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        if type == "clientdiag" {
            // #region agent log
            agentLog("H15", "YouTubePlayer.clientdiag", "webview client", [
                "safari": message["safari"] as? Bool ?? false,
                "version": message["version"] as? Bool ?? false,
                "chrome": message["chrome"] as? Bool ?? false,
                "bower": message["bower"] as? Bool ?? false,
                "webdriver": message["webdriver"] as? Bool ?? false,
                "len": message["len"] as? Int ?? Int(message["len"] as? Double ?? -1),
            ])
            // #endregion
            return
        }
        if type == "pageprobe" {
            let requiresBrowser = message["bot"] as? Bool == true
            if requiresBrowser, pageKind == .watch,
               let id = pageVideoID, id == currentVideoID {
                errorMessage = "YouTube requires verification. Complete it here to continue playback in Bower."
            }
            // #region agent log
            agentLog("H2", "YouTubePlayer.pageprobe", "watch document", [
                "path": message["path"] as? String ?? "",
                "hasSAPISID": message["hasSAPISID"] as? Bool ?? false,
                "hasSID": message["hasSID"] as? Bool ?? false,
                "hasLOGIN": message["hasLOGIN"] as? Bool ?? false,
                "bot": message["bot"] as? Bool ?? false,
                "blocked": message["blocked"] as? Bool ?? false,
                "hasVideo": message["hasVideo"] as? Bool ?? false,
                "time": message["time"] as? Double ?? -1,
                "paused": message["paused"] as? Bool ?? true,
                "ready": message["ready"] as? String ?? "",
            ])
            // #endregion
            return
        }
        if type == "cookiediag" {
            // #region agent log
            agentLog("H9", "YouTubePlayer.cookiediag", "cookie test", [
                "host": message["host"] as? String ?? "",
                "path": message["path"] as? String ?? "",
                "enabled": message["enabled"] as? Bool ?? false,
                "write": message["write"] as? Bool ?? false,
                "jar": message["jar"] as? Bool ?? false,
            ])
            // #endregion
            return
        }
        if type == "playerfetch" {
            // #region agent log
            func num(_ key: String) -> Int {
                if let value = message[key] as? Int { return value }
                if let value = message[key] as? Double { return Int(value) }
                return -1
            }
            agentLog("H26", "YouTubePlayer.playerfetch", "player request", [
                "http": num("http"),
                "status": message["status"] as? String ?? "",
                "formats": num("formats"),
                "adaptive": num("adaptive"),
                "urlCount": num("urlCount"),
                "cipherCount": num("cipherCount"),
                "top": message["top"] as? Bool ?? false,
                "path": message["path"] as? String ?? "",
                "itag": num("itag"),
                "mime": message["mime"] as? String ?? "",
                "videoOk": message["videoOk"] as? Bool ?? false,
                "sabr": message["sabr"] as? Bool ?? false,
                "hasN": message["hasN"] as? Bool ?? false,
                "detailsId": message["detailsId"] as? String ?? "",
                "watchId": message["watchId"] as? String ?? "",
                "askedId": message["askedId"] as? String ?? "",
                "bodyLen": num("bodyLen"),
            ])
            // #endregion
            return
        }
        if type == "attachdiag" {
            // #region agent log
            func num(_ key: String) -> Int {
                if let value = message[key] as? Int { return value }
                if let value = message[key] as? Double { return Int(value) }
                return -1
            }
            agentLog("H31", "YouTubePlayer.attachdiag", "attach stream", [
                "hasDirect": message["hasDirect"] as? Bool ?? false,
                "own": message["own"] as? Bool ?? false,
                "assigned": message["assigned"] as? Bool ?? false,
                "time": (message["time"] as? Double) ?? Double(message["time"] as? Int ?? 0),
                "paused": message["paused"] as? Bool ?? true,
                "ready": num("ready"),
                "network": num("network"),
                "verr": num("verr"),
                "err": message["err"] as? String ?? "",
                "itag": num("itag"),
                "mime": message["mime"] as? String ?? "",
                "top": message["top"] as? Bool ?? false,
            ])
            // #endregion
            return
        }
        if type == "csp" {
            // #region agent log
            agentLog("H35", "YouTubePlayer.csp", "content security policy", [
                "directive": message["directive"] as? String ?? "",
                "kind": message["kind"] as? String ?? "",
            ])
            // #endregion
            return
        }
        if type == "mediaprobe" {
            // #region agent log
            if let urlString = message["url"] as? String, let mediaURL = URL(string: urlString), message["via"] as? String == "native" {
                Task { @MainActor in
                    await self.probeMedia(mediaURL, via: "webview-url")
                }
            } else {
                func num(_ key: String) -> Int {
                    if let value = message[key] as? Int { return value }
                    if let value = message[key] as? Double { return Int(value) }
                    return -1
                }
                agentLog("H32", "YouTubePlayer.mediaprobe", "stream response", [
                    "via": message["via"] as? String ?? "",
                    "http": num("http"),
                    "mime": message["mime"] as? String ?? "",
                    "cors": message["cors"] as? Bool ?? false,
                    "err": message["err"] as? String ?? "",
                ])
            }
            // #endregion
            return
        }
        if type == "ctx" {
            // #region agent log
            func num(_ key: String) -> Int {
                if let value = message[key] as? Int { return value }
                if let value = message[key] as? Double { return Int(value) }
                return -1
            }
            agentLog("H42", "YouTubePlayer.ctx", "page client", [
                "version": message["version"] as? String ?? "",
                "clientName": message["clientName"] as? String ?? "",
                "visitorLen": num("visitorLen"),
                "hasContext": message["hasContext"] as? Bool ?? false,
            ])
            // #endregion
            return
        }
        if type == "playdiag" {
            // #region agent log
            func num(_ key: String) -> Int {
                if let value = message[key] as? Int { return value }
                if let value = message[key] as? Double { return Int(value) }
                return -1
            }
            agentLog("H6", "YouTubePlayer.playdiag", "player response", [
                "loggedIn": message["loggedIn"] as? Bool ?? false,
                "status": message["status"] as? String ?? "",
                "reason": message["reason"] as? String ?? "",
                "hasStreaming": message["hasStreaming"] as? Bool ?? false,
                "formats": num("formats"),
                "adaptive": num("adaptive"),
                "vready": num("vready"),
                "network": num("network"),
                "verr": num("verr"),
                "hasSrc": message["hasSrc"] as? Bool ?? false,
                "lifted": message["lifted"] as? Bool ?? false,
            ])
            // #endregion
            return
        }
        if let video = message["video"] as? String, !video.isEmpty, video != currentVideoID { return }
        switch type {
        case "ready":
            isReady = true
            if let pending = pendingLoad {
                pendingLoad = nil
                call("ltLoad(\(Self.jsString(pending.id)), \(pending.start), \(pending.autoplay))")
            }
        case "state":
            let value = message["state"] as? Int ?? -1
            state = State(rawValue: value) ?? .unstarted
            updateTime(message)
            if state == .playing {
                errorMessage = nil
                if !reportedPlaying {
                    reportedPlaying = true
                    onStartedPlaying?()
                }
            } else if state == .ended {
                onEnded?()
            }
        case "time":
            updateTime(message)
            onProgress?(currentTime, duration)
        case "error":
            let code = message["code"] as? Int ?? 0
            let videoID = message["video"] as? String
            // #region agent log
            agentLog("H5", "YouTubePlayer.error", "player error", ["code": code, "pageKind": "\(pageKind)"])
            // #endregion
            if shouldLeaveEmbed(code, videoID: videoID) { return }
            if pageKind == .setup, code == 152 || code == 153 || code == 1503 { return }
            errorMessage = switch code {
            case 2: "This video ID is invalid."
            case 5: "This video can't be played in the HTML5 player."
            case 100: "This video was removed or made private."
            case 101, 150: "The owner doesn't allow this video to be played outside YouTube."
            case 1503: "YouTube asked for a sign-in confirmation and didn't start the video."
            default: "Playback failed (error \(code))."
            }
        default:
            break
        }
    }

    private func updateTime(_ message: [String: Any]) {
        if let time = message["time"] as? Double { currentTime = time }
        if let total = message["duration"] as? Double, total > 0 { duration = total }
    }

    // #region agent log
    private static let cookieDiagScript = """
    (function () {
      if (window.__bowerCookieDiag) return;
      window.__bowerCookieDiag = true;
      var write = false;
      try {
        document.cookie = 'bower_probe=1; path=/; SameSite=Lax';
        write = document.cookie.indexOf('bower_probe=') !== -1;
      } catch (e) {}
      try {
        window.webkit.messageHandlers.lt.postMessage({
          type: 'cookiediag',
          host: location.hostname,
          path: location.pathname,
          enabled: navigator.cookieEnabled,
          write: write,
          jar: (document.cookie || '').length > 0
        });
      } catch (e) {}
    })();
    """
    // #endregion

    /// Runs in every YouTube frame. `autoplay=1` marks a page this app loaded;
    /// the setup page's player iframe does not carry it, so it stays untouched.
    private static let bridgeScript = """
    (function () {
      if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;
      if (!window.__bowerClientDiag) {
        window.__bowerClientDiag = true;
        var ua = navigator.userAgent || '';
        try {
          window.webkit.messageHandlers.lt.postMessage({
            type: 'clientdiag',
            safari: ua.indexOf('Safari/') !== -1,
            version: ua.indexOf('Version/') !== -1,
            chrome: ua.indexOf('Chrome/') !== -1,
            bower: ua.indexOf('Bower') !== -1,
            webdriver: navigator.webdriver === true,
            len: ua.length
          });
        } catch (e) {}
      }
      var autoplay = /[?&]autoplay=1/.test(location.search);
      var watch = location.pathname.indexOf('/watch') === 0;
      if (watch && !document.getElementById('bower-player-fit')) {
        var style = document.createElement('style');
        style.id = 'bower-player-fit';
        style.textContent = 'ytd-masthead,#masthead-container,#secondary,#related,#comments,#below,ytd-watch-metadata,#guide,tp-yt-app-drawer{display:none!important}html,body{background:#000!important;overflow:hidden!important}ytd-player,#player-container,#player{position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;max-height:none!important;z-index:10000!important;background:#000!important}';
        (document.head || document.documentElement).appendChild(style);
      }
      var attempts = 0;
      var waits = 0;
      var lastState = null;
      var reportedError = false;
      function findVideo(root) {
        if (!root || !root.querySelector) return null;
        var direct = root.querySelector('video');
        if (direct) return direct;
        var nodes = root.querySelectorAll('*');
        for (var i = 0; i < nodes.length; i++) {
          if (nodes[i].shadowRoot) {
            var found = findVideo(nodes[i].shadowRoot);
            if (found) return found;
          }
        }
        return null;
      }
      function videoID() {
        var watchID = location.search.match(/[?&]v=([^&]+)/);
        if (watchID) return decodeURIComponent(watchID[1]);
        var embedID = location.pathname.match(/\\/embed\\/([^/?]+)/);
        return embedID ? embedID[1] : '';
      }
      function post(payload) {
        try { window.webkit.messageHandlers.lt.postMessage(payload); } catch (e) {}
      }
      function reportPlayer(http, body, asked) {
        var status = '';
        var formats = 0;
        var adaptive = 0;
        var urlCount = 0;
        var cipherCount = 0;
        var direct = '';
        var itag = 0;
        var mime = '';
        var videoOk = false;
        var sabr = false;
        var detailsId = '';
        try {
          var json = JSON.parse(body || '');
          status = (json.playabilityStatus && json.playabilityStatus.status) || '';
          detailsId = (json.videoDetails && json.videoDetails.videoId) || '';
          videoOk = detailsId === videoID();
          var sd = json.streamingData || {};
          sabr = !!sd.serverAbrStreamingUrl;
          var lists = [sd.formats || [], sd.adaptiveFormats || []];
          formats = lists[0].length;
          adaptive = lists[1].length;
          var fallback = null;
          for (var i = 0; i < lists.length; i++) {
            for (var j = 0; j < lists[i].length; j++) {
              var item = lists[i][j];
              if (item.url) {
                urlCount++;
                var itemMime = String(item.mimeType || '');
                if (!fallback && itemMime.indexOf('video/mp4') === 0) fallback = item;
                if (!direct && itemMime.indexOf('video/mp4') === 0 && itemMime.indexOf('mp4a') !== -1) {
                  direct = item.url;
                  itag = item.itag || 0;
                  mime = itemMime.slice(0, 48);
                }
              }
              if (item.signatureCipher || item.cipher) cipherCount++;
            }
          }
          if (!direct && fallback) {
            direct = fallback.url;
            itag = fallback.itag || 0;
            mime = String(fallback.mimeType || '').slice(0, 48);
          }
        } catch (e) {}
        post({ type: 'playerfetch', http: http, status: status, formats: formats, adaptive: adaptive, urlCount: urlCount, cipherCount: cipherCount, top: window.top === window, path: location.pathname, itag: itag, mime: mime, videoOk: videoOk, sabr: sabr, hasN: /[?&]n=/.test(direct), detailsId: detailsId, watchId: videoID(), askedId: asked || '', bodyLen: (body || '').length });
        if (status === 'OK' && direct && videoOk) {
          window.__bowerDirect = direct;
          window.__bowerItag = itag;
          window.__bowerMime = mime;
          attachDirect();
        }
      }
      function replayWatch() {
        if (window.__bowerReplay || !window.ytcfg || !ytcfg.get) return;
        var context = null;
        var version = '';
        var clientName = '';
        var visitorLen = 0;
        try {
          context = ytcfg.get('INNERTUBE_CONTEXT');
          version = String(ytcfg.get('INNERTUBE_CLIENT_VERSION') || '');
          clientName = String(ytcfg.get('INNERTUBE_CLIENT_NAME') || '');
          visitorLen = String(ytcfg.get('VISITOR_DATA') || '').length;
        } catch (e) {}
        post({ type: 'ctx', version: version.slice(0, 48), clientName: clientName.slice(0, 24), visitorLen: visitorLen, hasContext: !!context });
        if (!context) return;
        window.__bowerReplay = true;
        fetch('/youtubei/v1/player?prettyPrint=false', {
          method: 'POST',
          credentials: 'include',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ context: context, videoId: videoID() })
        }).catch(function () {});
      }
      if (!window.__bowerCsp) {
        window.__bowerCsp = true;
        document.addEventListener('securitypolicyviolation', function (e) {
          var blocked = String(e.blockedURI || '');
          post({
            type: 'csp',
            directive: String(e.violatedDirective || e.effectiveDirective || '').slice(0, 40),
            kind: blocked.indexOf('googlevideo') !== -1 ? 'googlevideo' : (blocked ? 'other' : 'empty')
          });
        });
      }
      function attachDirect() {
        var direct = window.__bowerDirect;
        if (!direct || window.__bowerProbed) return;
        window.__bowerProbed = true;
        post({ type: 'mediaprobe', url: direct, via: 'native' });
        fetch(direct, { method: 'HEAD' }).then(function (res) {
          post({ type: 'mediaprobe', via: 'head', http: res.status, mime: String(res.headers.get('content-type') || '').slice(0, 48), cors: true });
        }).catch(function (e) {
          post({ type: 'mediaprobe', via: 'head', http: 0, mime: '', cors: false, err: String(e && e.name || e).slice(0, 40) });
        });
        fetch(direct, { headers: { Range: 'bytes=0-1' } }).then(function (res) {
          post({ type: 'mediaprobe', via: 'page', http: res.status, mime: String(res.headers.get('content-type') || '').slice(0, 48), cors: true });
        }).catch(function (e) {
          post({ type: 'mediaprobe', via: 'page', http: 0, mime: '', cors: false, err: String(e && e.name || e).slice(0, 40) });
        });
      }
      if (!window.__bowerPlayerHook && window.fetch) {
        window.__bowerPlayerHook = true;
        var originalFetch = window.fetch;
        window.fetch = function (input) {
          var init = arguments[1] || {};
          var asked = '';
          try {
            if (typeof init.body === 'string') {
              var found = init.body.match(/"videoId"\\s*:\\s*"([^"]+)"/);
              if (found) asked = found[1];
            }
          } catch (e) {}
          var pending = originalFetch.apply(this, arguments);
          var raw = typeof input === 'string' ? input : (input && input.url) || '';
          if (String(raw).indexOf('/youtubei/v1/player') !== -1) {
            pending.then(function (res) {
              res.clone().text().then(function (body) { reportPlayer(res.status, body, asked); }).catch(function () {});
            }).catch(function () {});
          }
          return pending;
        };
      }
      function start(video) {
        if (!video.currentSrc && !video.src) return;
        var pending = video.play();
        if (pending && pending.catch) pending.catch(function () {});
      }
      window.addEventListener('message', function (event) {
        var data = event.data;
        if (!data || data.source !== 'bower') return;
        autoplay = true;
        var video = findVideo(document);
        if (!video) return;
        if (data.cmd === 'pause') { video.pause(); return; }
        if (data.cmd === 'seek') video.currentTime = Number(data.time) || 0;
        start(video);
      });
      setInterval(function () {
        if (watch) replayWatch();
        if (!autoplay && !watch) return;
        var video = findVideo(document);
        var text = document.body ? document.body.innerText.slice(0, 400) : '';
        if (!window.__bowerProbeAt || Date.now() - window.__bowerProbeAt > 2000) {
          window.__bowerProbeAt = Date.now();
          var jar = document.cookie || '';
          post({
            type: 'pageprobe',
            hasSAPISID: jar.indexOf('SAPISID=') !== -1,
            hasSID: /(?:^|; )SID=/.test(jar),
            hasLOGIN: jar.indexOf('LOGIN_INFO=') !== -1,
            bot: /请登录|Sign in to confirm|聊天机器人/.test(text),
            blocked: /此视频不能观看|152-4|Error 153/.test(text),
            hasVideo: !!video,
            time: video ? (video.currentTime || 0) : -1,
            paused: video ? video.paused : true,
            ready: document.readyState,
            path: location.pathname
          });
          var pr = window.ytInitialPlayerResponse || {};
          var ps = pr.playabilityStatus || {};
          var sd = pr.streamingData || {};
          post({
            type: 'playdiag',
            loggedIn: !!(window.ytcfg && window.ytcfg.get && window.ytcfg.get('LOGGED_IN')),
            status: String(ps.status || ''),
            reason: String(ps.reason || '').slice(0, 80),
            vready: video ? video.readyState : -1,
            network: video ? video.networkState : -1,
            verr: video && video.error ? video.error.code : 0,
            hasSrc: !!(video && (video.currentSrc || video.src)),
            lifted: !!(video && video.getAttribute('data-bower') === '1'),
            hasStreaming: !!pr.streamingData,
            formats: (sd.formats || []).length,
            adaptive: (sd.adaptiveFormats || []).length
          });
        }
        if (!reportedError && !video) {
          var code = 0;
          if (/Error 15[23]|152-4|Video player configuration error|此视频不能观看/.test(text)) code = 153;
          else if (/Sign in to confirm|确认你不是机器人|请登录/.test(text)) code = 1503;
          if (code && waits > 2) {
            reportedError = true;
            post({ type: 'error', code: code, video: videoID() });
          }
        }
        if (!video) { waits++; return; }
        attachDirect();
        var hasMedia = !!(video.currentSrc || video.src);
        var started = video.currentTime > 0.3;
        if (autoplay && hasMedia && video.paused && !video.ended && !started && attempts < 12) {
          attempts++;
          start(video);
        }
        if (watch && video.readyState >= 2 && video.getAttribute('data-bower') !== '1') {
          video.setAttribute('data-bower', '1');
          document.documentElement.appendChild(video);
          video.setAttribute('style', 'position:fixed;inset:0;width:100vw;height:100vh;z-index:2147483647;background:#000;object-fit:contain');
          video.controls = true;
        }
        var state = video.ended ? 0 : (!hasMedia || video.paused ? 2 : (video.readyState < 3 ? 3 : 1));
        var payload = {
          type: state === lastState ? 'time' : 'state',
          state: state,
          time: video.currentTime || 0,
          duration: isFinite(video.duration) ? video.duration : 0,
          video: videoID()
        };
        lastState = state;
        if (payload.type === 'state' || state === 1) post(payload);
      }, 500);
    })();
    """

    private static let html = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
      html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
      #player { position: absolute; inset: 0; width: 100%; height: 100%; }
    </style>
    </head>
    <body>
    <div id="player"></div>
    <script>
      var player = null;
      function post(m) { window.webkit.messageHandlers.lt.postMessage(m); }
      function snapshot(type, extra) {
        var m = { type: type };
        try { m.time = player.getCurrentTime(); m.duration = player.getDuration(); } catch (e) {}
        for (var k in extra) m[k] = extra[k];
        return m;
      }
      function onYouTubeIframeAPIReady() {
        player = new YT.Player('player', {
          width: '100%', height: '100%',
          host: 'https://www.youtube.com',
          playerVars: { playsinline: 1, enablejsapi: 1, iv_load_policy: 3, rel: 0, autoplay: 0,
                        hl: 'en', cc_lang_pref: 'en', origin: location.origin },
          events: {
            onReady: function () { post({ type: 'ready' }); },
            onStateChange: function (e) { post(snapshot('state', { state: e.data })); },
            onApiChange: ltPickCaptions,
            onError: function (e) { post({ type: 'error', code: e.data }); }
          }
        });
      }
      // cc_lang_pref is only a hint: an uploader's default track still wins.
      // So once the captions module loads, switch to English or turn
      // captions off. Once per video, so a track picked by hand stays put.
      var captionsPicked = false;
      function ltPickCaptions() {
        if (captionsPicked || !player || !player.getOption) return;
        var tracks = player.getOption('captions', 'tracklist');
        if (!tracks || !tracks.length) return;
        captionsPicked = true;
        var current = player.getOption('captions', 'track') || {};
        if (/^en/.test(current.languageCode || '')) return;
        var english = tracks.filter(function (t) { return /^en/.test(t.languageCode); })[0];
        player.setOption('captions', 'track', english ? { languageCode: english.languageCode } : {});
      }
      function ltLoad(id, start, autoplay) {
        if (!player) return;
        captionsPicked = false;
        var args = { videoId: id, startSeconds: start };
        if (autoplay) player.loadVideoById(args); else player.cueVideoById(args);
      }
      setInterval(function () {
        if (player && player.getPlayerState && player.getPlayerState() === 1) post(snapshot('time', {}));
      }, 1000);
      var tag = document.createElement('script');
      tag.src = 'https://www.youtube.com/iframe_api';
      document.head.appendChild(tag);
    </script>
    </body>
    </html>
    """
}

extension YouTubePlayer: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Links inside the player (title, channel, logo) open in the browser
        // rather than replacing the player page.
        if navigationAction.targetFrame?.isMainFrame != false,
           navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            if Self.isGoogleSignInURL(url) { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
        }
        // #region agent log
        if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url {
            agentLog("H11", "YouTubePlayer.navigate", "main frame", [
                "host": url.host ?? "",
                "path": url.path,
                "type": navigationAction.navigationType.rawValue,
                "autoplay": url.query?.contains("autoplay=1") ?? false,
            ])
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let names = Set(cookies.map(\.name))
            agentLog("H13", "YouTubePlayer.navigate", "jar at navigation", [
                "host": url.host ?? "",
                "path": url.path,
                "count": cookies.count,
                "google": cookies.filter { $0.domain.contains("google.com") }.count,
                "youtube": cookies.filter { $0.domain.contains("youtube.com") }.count,
                "hasGAPS": names.contains("__Host-GAPS") || names.contains("GAPS"),
                "hasChooser": names.contains("ACCOUNT_CHOOSER"),
            ])
        }
        // #endregion
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // #region agent log
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            let names = http.allHeaderFields.keys.compactMap { $0 as? String }
            agentLog("H12", "YouTubePlayer.response", "response", [
                "host": http.url?.host ?? "",
                "path": http.url?.path ?? "",
                "status": http.statusCode,
                "setCookie": names.contains { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame },
            ])
        }
        // #endregion
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, Self.isGoogleSignInURL(url) {
            webView.load(navigationAction.request)
        } else if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    private static func isGoogleSignInURL(_ url: URL) -> Bool {
        url.host?.lowercased() == "accounts.google.com"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reload()
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: YouTubePlayer?
    init(_ target: YouTubePlayer) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message.body)
    }
}

// #region agent log
private func agentLog(_ hypothesisId: String, _ location: String, _ message: String, _ data: [String: Any]) {
    let payload: [String: Any] = [
        "sessionId": "b1f5ea", "runId": "post-fix", "hypothesisId": hypothesisId,
        "location": location, "message": message, "data": data,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
    ]
    guard let raw = try? JSONSerialization.data(withJSONObject: payload) else { return }
    let url = URL(fileURLWithPath: "/Users/bill/Program/bower/.cursor/debug-b1f5ea.log")
    let line = raw + Data("\n".utf8)
    if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: line)
        try? handle.close()
    } else {
        try? line.write(to: url)
    }
}
// #endregion
