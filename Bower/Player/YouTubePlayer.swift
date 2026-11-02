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
        webView.navigationDelegate = self
        webView.uiDelegate = self
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
            send(.play)
            return
        }
        if pageVideoID == id, pageKind == .embed || pageKind == .watch {
            send(.play)
            return
        }
        playGeneration += 1
        let generation = playGeneration
        let start = currentTime
        Task { @MainActor in
            await CookieStore.shared.syncToWebKit(clearExisting: true)
            guard generation == self.playGeneration, self.currentVideoID == id else { return }
            // Embedding from this app is rejected (153 without a Referer, 152-4
            // when the document origin is youtube.com). The watch page is a
            // first-party youtube.com navigation, so it sends the account cookie.
            self.loadWatchPage(videoID: id, start: start)
        }
    }

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

    /// Runs in every YouTube frame. `autoplay=1` marks a page this app loaded;
    /// the setup page's player iframe does not carry it, so it stays untouched.
    private static let bridgeScript = """
    (function () {
      if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;
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
      function start(video) {
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
        if (!autoplay && !watch) return;
        var video = findVideo(document);
        var text = document.body ? document.body.innerText.slice(0, 400) : '';
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
        var started = video.currentTime > 0.3;
        if (autoplay && video.paused && !video.ended && !started && attempts < 12) {
          attempts++;
          start(video);
        }
        if (watch && video.readyState >= 2 && video.getAttribute('data-bower') !== '1') {
          video.setAttribute('data-bower', '1');
          document.documentElement.appendChild(video);
          video.setAttribute('style', 'position:fixed;inset:0;width:100vw;height:100vh;z-index:2147483647;background:#000;object-fit:contain');
          video.controls = true;
        }
        var state = video.ended ? 0 : (video.paused ? 2 : (video.readyState < 3 ? 3 : 1));
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
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
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
