import AppKit
import Observation
import WebKit

/// Drives the YouTube iframe player inside one long-lived WKWebView. The page
/// is loaded once; switching videos goes through the player's JS API, so the
/// player never reloads between videos.
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

    @ObservationIgnored private var pendingLoad: (id: String, start: Double, autoplay: Bool)?
    @ObservationIgnored private var currentVideoID: String?
    @ObservationIgnored private var reportedPlaying = false

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
        webView.customUserAgent = InnerTubeClient.userAgent
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .black
        super.init()

        controller.add(WeakMessageHandler(self), name: "lt")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        loadPage()
    }

    /// The page's origin, which the embed sees as its embedder. YouTube rejects
    /// embedders it can't identify (error 152) but accepts http://localhost.
    /// The port is fixed so the origin stays the same across launches.
    private static let pageOrigin = URL(string: "http://localhost:17422/")!

    func loadPage() {
        isReady = false
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
        currentTime = start ?? 0
        let start = (start ?? 0).rounded(.down)
        guard isReady else {
            pendingLoad = (videoID, start, autoplay)
            return
        }
        call("ltLoad(\(Self.jsString(videoID)), \(start), \(autoplay))")
    }

    func play() { call("player && player.playVideo()") }
    func pause() { call("player && player.pauseVideo()") }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: Double) {
        call("player && (player.seekTo(\(seconds), true), player.playVideo())")
    }

    func restart() {
        reportedPlaying = false
        call("player && (player.seekTo(0, true), player.playVideo())")
    }

    func stop() {
        currentVideoID = nil
        call("player && player.stopVideo()")
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
            errorMessage = switch code {
            case 2: "This video ID is invalid."
            case 5: "This video can't be played in the HTML5 player."
            case 100: "This video was removed or made private."
            case 101, 150: "The owner doesn't allow this video to be played outside YouTube."
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
                        origin: location.origin },
          events: {
            onReady: function () { post({ type: 'ready' }); },
            onStateChange: function (e) { post(snapshot('state', { state: e.data })); },
            onError: function (e) { post({ type: 'error', code: e.data }); }
          }
        });
      }
      function ltLoad(id, start, autoplay) {
        if (!player) return;
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
