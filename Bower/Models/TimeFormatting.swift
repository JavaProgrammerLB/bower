import Foundation

nonisolated enum RelativeTime {
    private static let units: [String: Double] = [
        "second": 1_000,
        "minute": 60_000,
        "hour": 3_600_000,
        "day": 86_400_000,
        "week": 604_800_000,
        "month": 2_592_000_000,
        "year": 31_536_000_000,
    ]

    /// Turns YouTube's "3 weeks ago" (also "Streamed 2 days ago") into an
    /// absolute timestamp in milliseconds. InnerTube offers no absolute upload
    /// date in list responses, so this approximation is all there is.
    static func parse(_ text: String) -> Double? {
        guard let match = text.firstMatch(of: /(?i)(\d+)\s+(second|minute|hour|day|week|month|year)s?\s+ago/),
              let amount = Double(match.1),
              let unit = units[match.2.lowercased()]
        else { return nil }
        return nowMilliseconds() - amount * unit
    }

    @MainActor
    static func format(_ date: Date?) -> String {
        guard let date else { return "" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @MainActor
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

nonisolated enum DurationText {
    static func format(seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// "1:02:03" → 3723. Used for clickable timestamps in descriptions.
    static func seconds(from text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}
