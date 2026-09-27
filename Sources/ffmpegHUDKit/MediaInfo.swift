import Foundation

/// What `ffprobe` says about a file: enough for the drop zone's summary line and for
/// turning `time=` into a progress fraction.
public struct MediaInfo: Equatable, Sendable {
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var videoCodec: String?
    public var audioCodec: String?
    public var formatName: String?
    public var size: Int64?

    public init(duration: Double? = nil, width: Int? = nil, height: Int? = nil, videoCodec: String? = nil,
                audioCodec: String? = nil, formatName: String? = nil, size: Int64? = nil) {
        self.duration = duration
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.formatName = formatName
        self.size = size
    }

    public var hasVideo: Bool { videoCodec != nil }
    public var hasAudio: Bool { audioCodec != nil }

    /// `0:12 · 1920×1080 · h264 / aac · 4.2 MB`.
    public var summary: String {
        var parts: [String] = []
        if let duration { parts.append(TimeFormat.clock(duration)) }
        if let width, let height { parts.append("\(width)×\(height)") }
        let codecs = [videoCodec, audioCodec].compactMap { $0 }
        if !codecs.isEmpty { parts.append(codecs.joined(separator: " / ")) }
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.isEmpty ? "no audio or video streams" : parts.joined(separator: " · ")
    }

    public var json: [String: Any] {
        var d: [String: Any] = ["summary": summary]
        if let duration { d["duration"] = duration }
        if let width { d["width"] = width }
        if let height { d["height"] = height }
        if let videoCodec { d["videoCodec"] = videoCodec }
        if let audioCodec { d["audioCodec"] = audioCodec }
        if let formatName { d["format"] = formatName }
        if let size { d["size"] = size }
        return d
    }

    /// Parses `ffprobe -v error -print_format json -show_format -show_streams`. Attached
    /// pictures (cover art) do not count as video.
    public static func parse(ffprobeJSON data: Data) -> MediaInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var info = MediaInfo()
        let format = root["format"] as? [String: Any] ?? [:]
        info.formatName = format["format_name"] as? String
        info.duration = number(format["duration"])
        info.size = number(format["size"]).map { Int64($0) }
        for stream in root["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            let attached = ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
            if type == "video", !attached, info.videoCodec == nil {
                info.videoCodec = stream["codec_name"] as? String
                info.width = stream["width"] as? Int
                info.height = stream["height"] as? Int
                if info.duration == nil { info.duration = number(stream["duration"]) }
            } else if type == "audio", info.audioCodec == nil {
                info.audioCodec = stream["codec_name"] as? String
                if info.duration == nil { info.duration = number(stream["duration"]) }
            }
        }
        return info
    }

    private static func number(_ value: Any?) -> Double? {
        if let s = value as? String { return Double(s) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}

/// Runs `ffprobe` on a file.
public enum Probe {
    public static func argv(ffprobe: String, path: String) -> [String] {
        [ffprobe, "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path]
    }

    public enum ProbeError: Error, CustomStringConvertible {
        case missingTool
        case failed(String)
        public var description: String {
            switch self {
            case .missingTool: return "ffprobe not found (brew install ffmpeg)"
            case .failed(let why): return why
            }
        }
    }

    /// Synchronous; call off the main thread.
    public static func run(_ path: String, ffprobe: String? = Executables.path("ffprobe")) -> Result<MediaInfo, ProbeError> {
        guard let ffprobe else { return .failure(.missingTool) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffprobe)
        task.arguments = Array(argv(ffprobe: ffprobe, path: path).dropFirst())
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return .failure(.failed("ffprobe failed to start: \(error.localizedDescription)")) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let info = MediaInfo.parse(ffprobeJSON: data) else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(message.isEmpty ? "not a media file ffmpeg can read" : message))
        }
        return .success(info)
    }

    /// Asynchronous, completion on the main queue.
    public static func run(_ path: String, completion: @escaping @Sendable (Result<MediaInfo, ProbeError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(path)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// Finds executables the way a login shell would. An app launched from Finder inherits a
/// bare PATH, so Homebrew prefixes are searched explicitly.
public enum Executables {
    public static let searchPaths: [String] = {
        let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (env + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).filter { seen.insert($0).inserted }
    }()

    public static func path(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
