import Foundation

/// One timed caption after the source track has been grouped into lines.
nonisolated struct CaptionCue: Sendable, Equatable {
    var startMs: Int
    var endMs: Int
    var source: String
    var text: String
}

/// Turns a YouTube timedtext payload into lines.
///
/// Manual captions arrive as a sentence per event. Auto-captions arrive as
/// a word per event, so those get joined until a pause or a sentence end.
/// The player then translates `source` and keeps the timing.
nonisolated enum CaptionTrack {
    static func cues(from body: String) -> [CaptionCue] {
        var raw = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("\u{feff}") { raw.removeFirst() }
        if raw.hasPrefix(")]}'"), let brace = raw.firstIndex(of: "{") {
            raw = String(raw[brace...])
        }
        let fragments: [Fragment]
        if raw.hasPrefix("{") {
            fragments = jsonFragments(raw)
        } else if raw.hasPrefix("<") {
            fragments = xmlFragments(raw)
        } else if raw.contains("-->") {
            fragments = vttFragments(raw)
        } else {
            fragments = []
        }
        return finalize(fragments)
    }

    fileprivate struct Fragment {
        var startMs: Int
        var endMs: Int
        var text: String
    }

    private static func jsonFragments(_ raw: String) -> [Fragment] {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return [] }

        var fragments: [Fragment] = []
        var buffer = ""
        var start: Int?
        var end = 0

        func flush() {
            let text = clean(buffer)
            if let start, !text.isEmpty {
                fragments.append(Fragment(startMs: start, endMs: max(end, start), text: text))
            }
            buffer = ""
            start = nil
            end = 0
        }

        func append(_ piece: String, eventStart: Int, eventEnd: Int, offset: Int) {
            let visible = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if visible.isEmpty {
                if start != nil, piece.contains(where: \.isWhitespace) { buffer += " " }
                return
            }
            if start == nil { start = eventStart + max(offset, 0) }
            buffer += piece
            end = max(end, eventEnd)
        }

        for event in events {
            guard let segs = event["segs"] as? [[String: Any]], !segs.isEmpty else { continue }
            let eventStart = integer(event["tStartMs"])
            let eventEnd = eventStart + max(integer(event["dDurationMs"]), 0)
            for seg in segs {
                let pieces = (seg["utf8"] as? String ?? "").components(separatedBy: "\n")
                let offset = integer(seg["tOffsetMs"])
                for (index, piece) in pieces.enumerated() {
                    if index > 0 { flush() }
                    append(piece, eventStart: eventStart, eventEnd: eventEnd, offset: offset)
                }
            }
            flush()
        }
        return fragments
    }

    private static func xmlFragments(_ raw: String) -> [Fragment] {
        let parser = XML(data: Data(raw.utf8))
        return parser.fragments
    }

    private static func vttFragments(_ raw: String) -> [Fragment] {
        var fragments: [Fragment] = []
        let lines = raw.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if let times = timestampRange(line) {
                index += 1
                var textLines: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty { break }
                    textLines.append(next)
                    index += 1
                }
                let text = clean(textLines.joined(separator: " "))
                if !text.isEmpty {
                    fragments.append(Fragment(startMs: times.0, endMs: max(times.1, times.0), text: text))
                }
            }
            index += 1
        }
        return fragments
    }

    /// Word-level auto-captions become readable lines. Sentence-level tracks
    /// are already long enough and stay as YouTube grouped them.
    private static func mergeWords(_ fragments: [Fragment]) -> [Fragment] {
        guard fragments.count > 1 else { return fragments }
        let short = fragments.filter { $0.text.count <= 8 }.count
        guard short * 2 > fragments.count else { return fragments }

        var merged: [Fragment] = []
        var buffer = ""
        var start = 0
        var end = 0

        func flush() {
            let text = clean(buffer)
            if !text.isEmpty {
                merged.append(Fragment(startMs: start, endMs: max(end, start), text: text))
            }
            buffer = ""
        }

        for fragment in fragments {
            let gap = buffer.isEmpty ? 0 : fragment.startMs - end
            if !buffer.isEmpty, gap > 1200 || buffer.count >= 80 || endsSentence(buffer) {
                flush()
            }
            if buffer.isEmpty {
                start = fragment.startMs
                buffer = fragment.text
            } else if needsSpace(buffer, fragment.text) {
                buffer += " " + fragment.text
            } else {
                buffer += fragment.text
            }
            end = max(end, max(fragment.endMs, fragment.startMs))
        }
        flush()
        return merged
    }

    private static func finalize(_ fragments: [Fragment]) -> [CaptionCue] {
        let lines = mergeWords(fragments)
        guard !lines.isEmpty else { return [] }
        var cues = lines.map {
            CaptionCue(startMs: $0.startMs, endMs: $0.endMs, source: $0.text, text: $0.text)
        }
        for index in cues.indices where cues[index].endMs <= cues[index].startMs {
            cues[index].endMs = cues[index].startMs + 1600
        }
        for index in cues.indices where index + 1 < cues.count {
            let next = cues[index + 1].startMs
            let gap = next - cues[index].endMs
            if gap > 0, gap < 400 {
                cues[index].endMs = next
            }
            if cues[index].endMs > next {
                cues[index].endMs = max(next, cues[index].startMs + 1)
            }
        }
        return Array(cues.prefix(4000))
    }

    fileprivate static func clean(_ raw: String) -> String {
        var text = raw
        for pattern in ["\\{[^}]*\\}", "<[^>]*>"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!。！？".contains(last)
    }

    private static func needsSpace(_ left: String, _ right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        if ".,!?;:，。！？、".contains(first) { return false }
        return last.isASCII && first.isASCII
    }

    private static func integer(_ value: Any?) -> Int {
        switch value {
        case let number as Int: number
        case let number as Double: Int(number)
        case let number as NSNumber: number.intValue
        default: 0
        }
    }

    private static func timestampRange(_ line: String) -> (Int, Int)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = milliseconds(parts[0]),
              let end = milliseconds(parts[1]) else { return nil }
        return (start, end)
    }

    private static func milliseconds(_ stamp: String) -> Int? {
        let token = stamp.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let parts = token.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var hours = 0
        var minutes = 0
        let secondsText: String
        if parts.count == 3 {
            hours = Int(parts[0]) ?? -1
            minutes = Int(parts[1]) ?? -1
            secondsText = parts[2]
        } else {
            minutes = Int(parts[0]) ?? -1
            secondsText = parts[1]
        }
        let secBits = secondsText.split(separator: ".", maxSplits: 1).map(String.init)
        let seconds = Int(secBits[0]) ?? -1
        var millis = 0
        if secBits.count == 2 {
            var fraction = secBits[1]
            if fraction.count > 3 { fraction = String(fraction.prefix(3)) }
            while fraction.count < 3 { fraction.append("0") }
            millis = Int(fraction) ?? 0
        }
        guard hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    private final class XML: NSObject, XMLParserDelegate {
        var fragments: [Fragment] = []
        private var startMs = 0
        private var durationMs = 0
        private var text = ""
        private var inParagraph = false

        init(data: Data) {
            super.init()
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if elementName == "p" {
                inParagraph = true
                startMs = Int(attributeDict["t"] ?? "") ?? 0
                durationMs = Int(attributeDict["d"] ?? "") ?? 0
                text = ""
            } else if elementName == "br", inParagraph {
                text += " "
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inParagraph { text += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName == "p" else { return }
            inParagraph = false
            let cleaned = CaptionTrack.clean(text)
            guard !cleaned.isEmpty else { return }
            fragments.append(Fragment(startMs: startMs, endMs: startMs + max(durationMs, 0), text: cleaned))
        }
    }
}

/// Translates caption lines into Simplified Chinese.
///
/// The Edge browser endpoint is the one Immersive Translate-style clients moved
/// to after Microsoft retired the old auth token. Google's dictionary client is
/// the fallback when that endpoint refuses a batch.
actor CaptionTranslator {
    static let shared = CaptionTranslator()

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let session: URLSession
    private var cache: [String: String] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    /// Publishes each finished batch so a long video shows Chinese before the
    /// rest of the track has been translated. Empty means the track is already
    /// Chinese, or nothing could be translated.
    func translate(
        body: String,
        lang: String,
        tlang: String,
        onUpdate: (@Sendable ([CaptionCue]) -> Void)? = nil
    ) async -> [CaptionCue] {
        if Self.isChinese(lang) || Self.isChinese(tlang) { return [] }
        guard body.count < 1_500_000 else { return [] }
        let cues = CaptionTrack.cues(from: body)
        guard !cues.isEmpty else { return [] }
        if Self.mostlyChinese(cues.prefix(8).map(\.source).joined(separator: " ")) { return [] }

        let sources = cues.map(\.source)
        var translated = Array(repeating: "", count: sources.count)
        var unique: [String] = []
        var seen = Set<String>()
        for (index, source) in sources.enumerated() {
            if let hit = cache[source] {
                translated[index] = hit
            } else if !Self.needsTranslation(source) {
                translated[index] = source
            } else if seen.insert(source).inserted {
                unique.append(source)
            }
        }

        func fillFromCache() {
            for index in translated.indices where translated[index].isEmpty {
                if let hit = cache[sources[index]] {
                    translated[index] = hit
                }
            }
        }

        func prefix() -> [CaptionCue] {
            var output: [CaptionCue] = []
            var changed = false
            for (index, cue) in cues.enumerated() {
                let text = translated[index]
                if text.isEmpty { break }
                if text != cue.source { changed = true }
                output.append(CaptionCue(startMs: cue.startMs, endMs: cue.endMs, source: cue.source, text: text))
            }
            return changed ? output : []
        }

        let from = Self.sourceLanguage(lang)
        if !unique.isEmpty {
            for batch in Self.chunks(unique) {
                guard let lines = await translateBatch(batch, from: from), lines.count == batch.count else { break }
                for (offset, source) in batch.enumerated() where !lines[offset].isEmpty {
                    cache[source] = lines[offset]
                }
                fillFromCache()
                let partial = prefix()
                if !partial.isEmpty { onUpdate?(partial) }
            }
        }

        if cache.count > 12_000 { cache.removeAll(keepingCapacity: true) }

        for index in translated.indices where translated[index].isEmpty {
            translated[index] = cache[sources[index]] ?? sources[index]
        }
        var changed = false
        var output: [CaptionCue] = []
        output.reserveCapacity(cues.count)
        for (index, cue) in cues.enumerated() {
            let text = translated[index]
            if text != cue.source { changed = true }
            output.append(CaptionCue(startMs: cue.startMs, endMs: cue.endMs, source: cue.source, text: text))
        }
        let finished = changed ? output : []
        if !finished.isEmpty { onUpdate?(finished) }
        return finished
    }

    private static func isChinese(_ lang: String) -> Bool {
        lang.lowercased().hasPrefix("zh")
    }

    private static func needsTranslation(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Official Chinese captions, and YouTube's own `tlang` translation, should
    /// stay in the player's caption window instead of being translated again.
    private static func mostlyChinese(_ text: String) -> Bool {
        var han = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                han += 1
                letters += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
        }
        return letters >= 8 && han * 2 > letters
    }

    /// YouTube's `iw` is Hebrew. Anything else is the ISO subtag Bing and
    /// Google already accept; unknown tags fall through to autodetect.
    private static func sourceLanguage(_ lang: String) -> String? {
        let lower = lang.lowercased()
        if lower.isEmpty || lower.hasPrefix("zh") { return nil }
        if lower == "iw" || lower.hasPrefix("iw-") { return "he" }
        let primary = lower.split(separator: "-").first.map(String.init) ?? lower
        guard (2...3).contains(primary.count), primary.allSatisfy(\.isLetter) else { return nil }
        return primary
    }

    private nonisolated func translateBatch(_ texts: [String], from: String?) async -> [String]? {
        if let lines = await edgeTranslate(texts, from: from), lines.count == texts.count {
            return lines
        }
        if let lines = await googleTranslate(texts, from: from), lines.count == texts.count {
            return lines
        }
        return nil
    }

    private nonisolated func edgeTranslate(_ texts: [String], from: String?) async -> [String]? {
        guard var components = URLComponents(string: "https://edge.microsoft.com/translate/translatetext") else { return nil }
        var items = [
            URLQueryItem(name: "to", value: "zh-Hans"),
            URLQueryItem(name: "isEnterpriseClient", value: "false"),
        ]
        if let from, !from.isEmpty {
            items.insert(URLQueryItem(name: "from", value: from), at: 0)
        }
        components.queryItems = items
        guard let url = components.url,
              let body = try? JSONSerialization.data(withJSONObject: texts) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request)
        guard let data = await data(for: request),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let lines = rows.compactMap { row -> String? in
            (row["translations"] as? [[String: Any]])?.first?["text"] as? String
        }
        return lines.count == texts.count ? lines : nil
    }

    private nonisolated func googleTranslate(_ texts: [String], from: String?) async -> [String]? {
        guard var components = URLComponents(string: "https://clients5.google.com/translate_a/t") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "client", value: "dict-chrome-ex"),
            URLQueryItem(name: "sl", value: from ?? "auto"),
            URLQueryItem(name: "tl", value: "zh-CN"),
        ]
        var form = URLComponents()
        form.queryItems = texts.map { URLQueryItem(name: "q", value: $0) }
        guard let url = components.url,
              let body = form.percentEncodedQuery?.data(using: .utf8) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request)
        guard let data = await data(for: request),
              let lines = try? JSONSerialization.jsonObject(with: data) as? [String],
              lines.count == texts.count else { return nil }
        return lines
    }

    private nonisolated func data(for request: URLRequest) async -> Data? {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }
        return data
    }

    private nonisolated func applyHeaders(to request: inout URLRequest) {
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    }

    private static func chunks(_ texts: [String]) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var count = 0
        for text in texts {
            if !current.isEmpty, current.count >= 40 || count + text.utf16.count > 3500 {
                batches.append(current)
                current = []
                count = 0
            }
            current.append(text)
            count += text.utf16.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

/// Page script for the watch and embed documents.
///
/// Same shape as Immersive Translate's YouTube path: hook `fetch` and XHR
/// before the player reads `/api/timedtext`, translate that payload, draw a
/// caption layer on the player, and hide YouTube's own caption window.
nonisolated enum SubtitleScript {
    static let source = #"""
    (function () {
      if (!/(^|\.)youtube\.com$/.test(location.hostname || '')) return;
      if (location.pathname.indexOf('/watch') !== 0 && location.pathname.indexOf('/embed/') !== 0) return;
      if (window.__bowerSubtitleHook) return;
      window.__bowerSubtitleHook = true;

      var latest = 0;
      var lastKey = '';
      var queued = null;
      var armed = false;
      var armTries = 0;
      window.__bowerCues = [];
      window.__bowerSubtitleOn = false;

      function post(message) {
        try { window.webkit.messageHandlers.lt.postMessage(message); } catch (e) {}
      }
      function videoID() {
        var watchID = location.search.match(/[?&]v=([^&]+)/);
        if (watchID) return decodeURIComponent(watchID[1]);
        var embedID = location.pathname.match(/\/embed\/([^/?]+)/);
        return embedID ? embedID[1] : '';
      }
      function param(url, name) {
        var match = String(url).match(new RegExp('[?&]' + name + '=([^&]*)'));
        if (!match) return '';
        try { return decodeURIComponent(match[1].replace(/\+/g, ' ')); } catch (e) { return match[1]; }
      }
      function isTimedText(url) {
        return String(url).indexOf('/api/timedtext') !== -1;
      }
      function walk(root, selector) {
        if (!root || !root.querySelector) return null;
        var direct = root.querySelector(selector);
        if (direct) return direct;
        var nodes = root.querySelectorAll('*');
        for (var i = 0; i < nodes.length; i++) {
          if (nodes[i].shadowRoot) {
            var found = walk(nodes[i].shadowRoot, selector);
            if (found) return found;
          }
        }
        return null;
      }
      function playerAPI() {
        var hosts = [];
        var byId = document.getElementById('movie_player');
        if (byId) hosts.push(byId);
        var ytd = document.querySelectorAll('ytd-player');
        for (var i = 0; i < ytd.length; i++) hosts.push(ytd[i]);
        for (var j = 0; j < hosts.length; j++) {
          var host = hosts[j];
          if (host.getOption) return host;
          var inner = host.player || host.player_;
          if (inner && inner.getOption) return inner;
          if (host.shadowRoot) {
            var boxed = host.shadowRoot.querySelector('#movie_player');
            if (boxed && boxed.getOption) return boxed;
          }
        }
        return null;
      }
      function playerElement() {
        var api = playerAPI();
        if (api && api.nodeType === 1) return api;
        return walk(document, '.html5-video-player');
      }
      function pickTrack(tracks) {
        function find(re) {
          for (var i = 0; i < tracks.length; i++) {
            if (re.test(tracks[i].languageCode || '')) return tracks[i];
          }
          return null;
        }
        return find(/^zh-Hans|^zh-CN|^zh-SG/) || find(/^zh/) || find(/^en/) || tracks[0] || null;
      }
      function removeHide() {
        var roots = [];
        if (document.head) roots.push(document.head);
        var player = playerElement();
        if (player) {
          var root = player.getRootNode();
          if (root && root.nodeType === 11) roots.push(root);
        }
        for (var i = 0; i < roots.length; i++) {
          var style = roots[i].querySelector && roots[i].querySelector('#bower-cap-hide');
          if (style) style.remove();
        }
      }
      function teardown() {
        window.__bowerCues = [];
        if (window.__bowerCaptionBox) {
          window.__bowerCaptionBox.remove();
          window.__bowerCaptionBox = null;
        }
        removeHide();
      }
      function installHide(player) {
        var root = player.getRootNode();
        var parent = root && root.nodeType === 11 ? root : (document.head || document.documentElement);
        if (!parent || (parent.querySelector && parent.querySelector('#bower-cap-hide'))) return;
        var style = document.createElement('style');
        style.id = 'bower-cap-hide';
        style.textContent = '.caption-window,.ytp-caption-window-container{opacity:0!important}';
        parent.appendChild(style);
      }
      function ensureBox(player) {
        var box = window.__bowerCaptionBox;
        if (box && box.isConnected && box.parentNode === player) return box;
        if (box && box.remove) box.remove();
        box = document.createElement('div');
        box.id = 'bower-caption';
        box.setAttribute('aria-hidden', 'true');
        box.style.cssText = 'position:absolute;left:7%;right:7%;z-index:35;text-align:center;pointer-events:none;font-family:-apple-system,PingFang SC,Hiragino Sans GB,sans-serif;font-size:clamp(18px,2.7vh,34px);line-height:1.35;text-shadow:-1px -1px 0 #000,1px -1px 0 #000,-1px 1px 0 #000,1px 1px 0 #000,0 2px 6px #000;';
        var src = document.createElement('div');
        src.className = 'src';
        src.style.cssText = 'display:none;font-size:0.72em;font-weight:500;opacity:0.92;margin-bottom:2px;overflow:hidden;-webkit-line-clamp:2;-webkit-box-orient:vertical;';
        var dst = document.createElement('div');
        dst.className = 'dst';
        dst.style.cssText = 'display:-webkit-box;font-size:1em;font-weight:700;overflow:hidden;-webkit-line-clamp:3;-webkit-box-orient:vertical;';
        box.appendChild(src);
        box.appendChild(dst);
        player.appendChild(box);
        window.__bowerCaptionBox = box;
        return box;
      }
      function cueAt(ms) {
        var cues = window.__bowerCues || [];
        var lo = 0;
        var hi = cues.length - 1;
        while (lo <= hi) {
          var mid = (lo + hi) >> 1;
          var cue = cues[mid];
          if (ms < cue.start) hi = mid - 1;
          else if (ms >= cue.end) lo = mid + 1;
          else return cue;
        }
        return null;
      }
      function paint() {
        if (!window.__bowerSubtitleOn) return;
        var cues = window.__bowerCues;
        if (!cues || !cues.length) return;
        var player = playerElement();
        if (!player) return;
        var video = player.querySelector('video') || walk(document, 'video');
        var ms = video ? (video.currentTime || 0) * 1000 : 0;
        var cue = cueAt(ms);
        var box = ensureBox(player);
        box.style.bottom = player.classList.contains('ytp-autohide') ? '6%' : '14%';
        var src = box.querySelector('.src');
        var dst = box.querySelector('.dst');
        if (!cue) {
          box.style.display = 'none';
          return;
        }
        box.style.display = 'block';
        var source = cue.source || '';
        var text = cue.text || '';
        if (source && source !== text) {
          src.style.display = '-webkit-box';
          src.textContent = source;
        } else {
          src.style.display = 'none';
          src.textContent = '';
        }
        dst.textContent = text;
        installHide(player);
      }
      function armCaptions() {
        if (!window.__bowerSubtitleOn || armed) return;
        var player = playerAPI();
        if (!player || !player.getOption || !player.setOption) return;
        var tracks = [];
        try { tracks = player.getOption('captions', 'tracklist') || []; } catch (e) {}
        if (!tracks.length) {
          if (armTries < 40) {
            try { if (player.loadModule) player.loadModule('captions'); } catch (e) {}
          }
          armTries++;
          return;
        }
        var current = {};
        try { current = player.getOption('captions', 'track') || {}; } catch (e) {}
        var pick = pickTrack(tracks);
        if (!pick) return;
        var sameCode = (current.languageCode || '') === (pick.languageCode || '');
        var sameKind = !pick.vss_id || current.vss_id === pick.vss_id;
        if (current.languageCode && sameCode && sameKind) {
          armed = true;
          return;
        }
        var option = { languageCode: pick.languageCode };
        if (pick.vss_id) option.vss_id = pick.vss_id;
        if (pick.vssId) option.vssId = pick.vssId;
        if (pick.kind) option.kind = pick.kind;
        try { player.setOption('captions', 'track', option); } catch (e) {}
        armed = true;
      }
      function nudge() {
        var player = playerAPI();
        if (!player || !player.getOption || !player.setOption) return;
        var track = null;
        try { track = player.getOption('captions', 'track'); } catch (e) {}
        if (!track || !track.languageCode) {
          armed = false;
          armCaptions();
          return;
        }
        try {
          player.setOption('captions', 'track', {});
          player.setOption('captions', 'track', track);
        } catch (e) {}
      }
      function translateBody(body, url) {
        if (!window.__bowerSubtitleOn) return;
        if (!body || body.length < 2 || body.length > 1500000) return;
        url = String(url || '');
        if (url.indexOf('type=list') !== -1) return;
        var lang = param(url, 'lang');
        var tlang = param(url, 'tlang');
        if (/^zh/i.test(lang) || /^zh/i.test(tlang)) {
          teardown();
          return;
        }
        var key = body.length + ':' + body.slice(0, 120) + ':' + body.slice(-80);
        if (key === lastKey) return;
        lastKey = key;
        var id = String(++latest);
        post({ type: 'subtitle', id: id, lang: lang, tlang: tlang, video: videoID(), body: body });
      }
      function noteSubtitle(body, url) {
        if (!body) return;
        queued = { body: body, url: String(url || '') };
        if (window.__bowerSubtitleOn) translateBody(queued.body, queued.url);
      }
      window.__bowerSubtitleDone = function (id, cues) {
        if (String(id) !== String(latest)) return;
        if (!window.__bowerSubtitleOn) return;
        if (!cues || !cues.length) return;
        window.__bowerCues = cues;
        paint();
      };
      window.__bowerApplySubtitleCfg = function (on) {
        var was = window.__bowerSubtitleOn;
        window.__bowerSubtitleOn = !!on;
        if (!on) {
          teardown();
          return;
        }
        if (queued) {
          var item = queued;
          lastKey = '';
          translateBody(item.body, item.url);
        } else if (was === false) {
          nudge();
        }
        armCaptions();
        paint();
      };

      if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function (input) {
          var url = '';
          try { url = typeof input === 'string' ? input : (input && input.url) || ''; } catch (e) {}
          var pending = origFetch.apply(this, arguments);
          if (!isTimedText(url)) return pending;
          return pending.then(function (res) {
            try {
              res.clone().text().then(function (body) { noteSubtitle(body, url); }).catch(function () {});
            } catch (e) {}
            return res;
          });
        };
      }
      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { this.__bowerCapURL = url == null ? '' : String(url); } catch (e) {}
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function (body) {
        var xhr = this;
        var url = '';
        try { url = xhr.__bowerCapURL || ''; } catch (e) {}
        if (isTimedText(url)) {
          xhr.addEventListener('load', function () {
            var text = '';
            try { text = xhr.responseText || ''; } catch (e) { return; }
            noteSubtitle(text, url);
          });
        }
        return origSend.apply(this, arguments);
      };
      setInterval(function () {
        armCaptions();
        paint();
      }, 250);
      post({ type: 'subtitlecfg' });
    })();
    """#
}

#if CAPTION_TEST
@main
struct CaptionTestMain {
    static func main() async {
        var failed = false
        func check(_ name: String, _ body: String, _ expected: [(Int, Int, String)]) {
            let got = CaptionTrack.cues(from: body).map { ($0.startMs, $0.endMs, $0.source) }
            let same = got.count == expected.count && zip(got, expected).allSatisfy { $0 == $1 }
            if same {
                print("ok \(name)")
            } else {
                failed = true
                print("FAIL \(name)")
                print("  got \(got)")
            }
        }

        check("sentences", #"{"events":[{"tStartMs":80,"dDurationMs":3910,"segs":[{"utf8":"hello world"}]},{"tStartMs":4080,"dDurationMs":2500,"segs":[{"utf8":"next line"}]}]}"#, [
            (80, 4080, "hello world"),
            (4080, 6580, "next line"),
        ])
        check("asr", #"{"events":[{"tStartMs":1000,"dDurationMs":300,"segs":[{"utf8":"Hello"}]},{"tStartMs":1300,"dDurationMs":200,"segs":[{"utf8":" there."}]},{"tStartMs":1600,"dDurationMs":100,"segs":[{"utf8":"\n"}]},{"tStartMs":2000,"dDurationMs":400,"segs":[{"utf8":"How"},{"tOffsetMs":100,"utf8":" are"},{"tOffsetMs":200,"utf8":" you?"}]}]}"#, [
            (1000, 1500, "Hello there."),
            (2000, 2400, "How are you?"),
        ])
        check("words", #"{"events":[{"tStartMs":0,"dDurationMs":200,"segs":[{"utf8":"Hello"}]},{"tStartMs":200,"dDurationMs":200,"segs":[{"utf8":"there."}]},{"tStartMs":2000,"dDurationMs":200,"segs":[{"utf8":"Next"}]},{"tStartMs":2200,"dDurationMs":200,"segs":[{"utf8":"sentence"}]}]}"#, [
            (0, 400, "Hello there."),
            (2000, 2400, "Next sentence"),
        ])
        check("tag", #"{"events":[{"tStartMs":10,"dDurationMs":1000,"segs":[{"utf8":"{\\an8}hello world"}]}]}"#, [
            (10, 1010, "hello world"),
        ])
        check("xml", "<timedtext><body><p t=\"1000\" d=\"2500\">Hello there.</p><p t=\"4000\" d=\"2000\">Next line</p></body></timedtext>", [
            (1000, 3500, "Hello there."),
            (4000, 6000, "Next line"),
        ])
        check("vtt", "WEBVTT\n\n00:00:01.000 --> 00:00:03.500\nHello there.\n\n00:00:04.000 --> 00:00:06.000\nNext line\n", [
            (1000, 3500, "Hello there."),
            (4000, 6000, "Next line"),
        ])

        let skipped = await CaptionTranslator.shared.translate(body: #"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"Hello"}]}]}"#, lang: "zh-Hans", tlang: "")
        if skipped.isEmpty {
            print("ok skip chinese track")
        } else {
            failed = true
            print("FAIL skip chinese track")
        }
        let sample = #"{"events":[{"tStartMs":0,"dDurationMs":2000,"segs":[{"utf8":"Hello there."}]},{"tStartMs":2000,"dDurationMs":2000,"segs":[{"utf8":"How are you?"}]}]}"#
        let cues = await CaptionTranslator.shared.translate(body: sample, lang: "en", tlang: "")
        let chinese = cues.allSatisfy { cue in
            cue.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        if cues.count == 2, chinese {
            print("ok translate \(cues[0].source) -> \(cues[0].text) | \(cues[1].source) -> \(cues[1].text)")
        } else {
            failed = true
            print("FAIL translate count=\(cues.count) \(cues)")
        }
        if failed { exit(EXIT_FAILURE) }
    }
}
#endif
