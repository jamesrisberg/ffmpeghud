import Foundation

/// Reads ffmpeg's stderr status lines (`frame=  48 fps=0.0 ... time=00:00:01.60 bitrate=...`).
public enum ProgressParser {
    /// Seconds of output written so far, from `time=HH:MM:SS.xx`; nil for other lines and
    /// for `time=N/A`.
    public static func time(in line: String) -> Double? {
        guard let range = line.range(of: "time=") else { return nil }
        let rest = line[range.upperBound...].drop { $0 == " " }
        let token = rest.prefix { !$0.isWhitespace }
        guard !token.hasPrefix("-") else { return 0 }
        return TimeFormat.seconds(String(token))
    }

    /// `speed=2.5x` -> 2.5.
    public static func speed(in line: String) -> Double? {
        guard let range = line.range(of: "speed=") else { return nil }
        let token = line[range.upperBound...].drop { $0 == " " }.prefix { !$0.isWhitespace }
        return Double(token.hasSuffix("x") ? String(token.dropLast()) : String(token))
    }

    /// Whether a line is a status line (shown as progress, not kept as a log/error line).
    public static func isStatus(_ line: String) -> Bool {
        (line.hasPrefix("frame=") || line.hasPrefix("size=")) && line.contains("time=")
    }

    /// `time` over `expected`, clamped to 0...1; nil when the length is unknown.
    public static func fraction(time: Double, expected: Double?) -> Double? {
        guard let expected, expected > 0 else { return nil }
        return min(1, max(0, time / expected))
    }

    /// How long the output will be, given the input's duration and the form: trims start and
    /// cap it, speed divides it, a thumbnail is one frame. nil when unknown.
    public static func expectedDuration(total: Double?, preset: Preset, values: PresetValues) -> Double? {
        if preset.id == PresetCatalog.thumbnail.id { return nil }
        var length = total
        if preset.inputArgs.contains(where: { if case .when(let f, _) = $0 { return f == "start" }; return false }),
           let start = TimeFormat.seconds(values["start"]), let t = length {
            length = max(0, t - start)
        }
        if preset.field("duration") != nil, let cap = TimeFormat.seconds(values["duration"]) {
            length = length.map { min($0, cap) } ?? cap
        }
        if preset.field("factor") != nil, let factor = Double(values["factor"]), factor > 0 {
            length = length.map { $0 / factor }
        }
        return length
    }
}

/// Most-recently-used preset ids, newest first, and the preset list ordered by them.
public enum Recents {
    public static let limit = 20

    public static func touch(_ id: String, in recents: [String]) -> [String] {
        Array(([id] + recents.filter { $0 != id }).prefix(limit))
    }

    /// Recently used first (newest first), then the rest in catalog order; `query` matches
    /// title, id or summary, case-insensitively.
    public static func ordered(_ presets: [Preset], recents: [String], query: String = "") -> [Preset] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = q.isEmpty ? presets : presets.filter {
            $0.title.lowercased().contains(q) || $0.id.contains(q) || $0.summary.lowercased().contains(q)
        }
        let rank = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let catalog = Dictionary(presets.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return matching.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return catalog[a.id, default: 0] < catalog[b.id, default: 0]
            }
        }
    }
}
