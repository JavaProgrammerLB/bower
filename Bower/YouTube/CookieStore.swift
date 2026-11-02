import Foundation
import Synchronization
import WebKit

/// The YouTube `Cookie` header the user pasted in. It signs InnerTube requests
/// and is mirrored into the web view's cookie jar so the embedded player is
/// signed in too — anonymous playback is what YouTube's bot check targets.
///
/// Kept as a plain file in the app's data folder (mode 0600): anything running
/// as this user could read the browser profile it came from just as easily.
nonisolated final class CookieStore: Sendable {
    static let shared = CookieStore()

    private let value: Mutex<String>

    private init() {
        let stored = (try? String(contentsOf: AppPaths.cookie, encoding: .utf8)) ?? ""
        value = Mutex(stored.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var cookie: String { value.withLock { $0 } }

    var hasCookie: Bool { !cookie.isEmpty }

    func set(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.withLock { $0 = trimmed }
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: AppPaths.cookie)
        } else {
            try? trimmed.write(to: AppPaths.cookie, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.cookie.path)
        }
    }

    static func pairs(_ cookie: String) -> [(String, String)] {
        cookie.split(separator: ";").compactMap { part in
            guard let eq = part.firstIndex(of: "=") else { return nil }
            let name = part[..<eq].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty || value.isEmpty ? nil : (name, value)
        }
    }

    var sapisid: String? {
        let pairs = Self.pairs(cookie)
        return pairs.first { $0.0 == "SAPISID" }?.1 ?? pairs.first { $0.0 == "__Secure-3PAPISID" }?.1
    }
}

extension CookieStore {
    /// Replaces the web view's youtube.com cookies with the stored ones. With
    /// no stored cookie, the player keeps building its own visitor session.
    @MainActor
    func syncToWebKit(clearExisting: Bool) async {
        let jar = WKWebsiteDataStore.default().httpCookieStore
        if clearExisting {
            for existing in await jar.allCookies() where existing.domain.hasSuffix("youtube.com") {
                await jar.deleteCookie(existing)
            }
        }
        let expiry = Date().addingTimeInterval(60 * 60 * 24 * 365)
        // A leading-dot domain is stored and then ignored by the watch page, so
        // the player never sees SAPISID and treats the visit as anonymous.
        // Host-only cookies for www.youtube.com show up in the document.
        let origin = URL(string: "https://www.youtube.com")!
        var created = 0
        var skipped = 0
        for (name, value) in Self.pairs(cookie) {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: "www.youtube.com",
                .path: "/",
                .name: name,
                .value: value,
                .secure: "TRUE",
                .expires: expiry,
                .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax,
                .originURL: origin,
            ]
            if let cookie = HTTPCookie(properties: properties) {
                await jar.setCookie(cookie)
                created += 1
            } else {
                skipped += 1
            }
        }
        // #region agent log
        let names = Set((await jar.allCookies()).map(\.name))
        agentLog("H1", "CookieStore.syncToWebKit", "jar after sync", [
            "clearExisting": clearExisting,
            "created": created,
            "skipped": skipped,
            "jarCount": names.count,
            "hasSAPISID": names.contains("SAPISID"),
            "hasSID": names.contains("SID"),
            "hasLOGIN": names.contains("LOGIN_INFO"),
        ])
        // #endregion
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

/// Accepts either form a user can get without tooling: the `cookie:` request
/// header copied from devtools, or a Netscape `cookies.txt` export.
nonisolated struct ParsedCookie {
    var cookie: String
    var names: [String]
    var hasSAPISID: Bool

    private static let acceptedDomains: Set<String> = [".youtube.com", "youtube.com", ".google.com", "google.com"]

    init(input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNetscape = text.split(separator: "\n").contains { $0.split(separator: "\t", omittingEmptySubsequences: false).count >= 7 }
        var pairs: [(String, String)] = []

        if isNetscape {
            for rawLine in text.split(separator: "\n") {
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#HttpOnly_") { line.removeFirst("#HttpOnly_".count) }
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 7, Self.acceptedDomains.contains(fields[0].lowercased()) else { continue }
                let name = fields[5].trimmingCharacters(in: .whitespaces)
                let value = fields[6].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !value.isEmpty { pairs.append((name, value)) }
            }
        } else {
            let header = text.replacingOccurrences(of: #"^(?i)cookie:\s*"#, with: "", options: .regularExpression)
            pairs = CookieStore.pairs(header)
        }

        // The same name can appear for several domains; the last one wins.
        var order: [String] = []
        var values: [String: String] = [:]
        for (name, value) in pairs {
            if values[name] == nil { order.append(name) }
            values[name] = value
        }
        names = order
        cookie = order.map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
        hasSAPISID = order.contains("SAPISID") || order.contains("__Secure-3PAPISID")
    }
}
