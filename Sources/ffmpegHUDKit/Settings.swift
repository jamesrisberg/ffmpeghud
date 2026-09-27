import Foundation

/// User settings (schema: Sources/ffmpegHUD/Resources/settings.json), stored as JSON at `<home>/preferences.json`.
public struct FFmpegSettings: Codable, Equatable, Sendable {
    public enum Folder: String, Codable, CaseIterable, Sendable { case same, movies, custom }

    /// Where results go: next to the original, ~/Movies, or `customFolder`.
    public var outputFolder: Folder = .same
    public var customFolder: String = ""
    /// Added to the original's name; `{preset}` is the preset's word.
    public var namingSuffix: String = "_{preset}"
    /// Off: the original goes to the Trash after a job succeeds.
    public var keepOriginal: Bool = true
    /// Jobs running at once.
    public var concurrentJobs: Int = 2

    public init() {}

    public static let concurrentRange = 1...8

    enum CodingKeys: String, CodingKey {
        case outputFolder = "output.folder"
        case customFolder = "output.customFolder"
        case namingSuffix = "naming.suffix"
        case keepOriginal
        case concurrentJobs = "jobs.concurrent"
    }

    /// Saved values are merged over the defaults key by key: a missing key, or one whose value no
    /// longer decodes, keeps its default and the other saved values are kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FFmpegSettings()
        outputFolder = (try? c.decodeIfPresent(Folder.self, forKey: .outputFolder)) ?? d.outputFolder
        customFolder = (try? c.decodeIfPresent(String.self, forKey: .customFolder)) ?? d.customFolder
        namingSuffix = (try? c.decodeIfPresent(String.self, forKey: .namingSuffix)) ?? d.namingSuffix
        keepOriginal = (try? c.decodeIfPresent(Bool.self, forKey: .keepOriginal)) ?? d.keepOriginal
        concurrentJobs = (try? c.decodeIfPresent(Int.self, forKey: .concurrentJobs)) ?? d.concurrentJobs
    }

    public var json: [String: Any] {
        ["output.folder": outputFolder.rawValue, "output.customFolder": customFolder,
         "naming.suffix": namingSuffix, "keepOriginal": keepOriginal, "jobs.concurrent": concurrentJobs]
    }

    public enum SettingsError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String { if case .invalid(let s) = self { return s }; return "" }
    }

    /// Applies string values (from `settings set`), validating all before changing any.
    public func applying(_ values: [String: String]) throws -> FFmpegSettings {
        var copy = self
        for (key, value) in values {
            switch key {
            case "output.folder":
                guard let folder = Folder(rawValue: value) else {
                    throw SettingsError.invalid("output.folder must be same, movies or custom")
                }
                copy.outputFolder = folder
            case "output.customFolder":
                copy.customFolder = value
            case "naming.suffix":
                guard !value.contains("/"), !value.contains(":") else {
                    throw SettingsError.invalid("naming.suffix cannot contain / or :")
                }
                copy.namingSuffix = value
            case "keepOriginal":
                copy.keepOriginal = try Self.bool(value, key)
            case "jobs.concurrent":
                guard let n = Int(value), Self.concurrentRange.contains(n) else {
                    throw SettingsError.invalid("jobs.concurrent must be a whole number from 1 to 8")
                }
                copy.concurrentJobs = n
            default:
                throw SettingsError.invalid("unknown setting \(key)")
            }
        }
        if copy.outputFolder == .custom, copy.customFolder.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SettingsError.invalid("output.folder custom needs output.customFolder")
        }
        return copy
    }

    static func bool(_ value: String, _ key: String) throws -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw SettingsError.invalid("\(key) must be true or false")
        }
    }

    public static func load(from url: URL) -> FFmpegSettings {
        guard let data = try? Data(contentsOf: url) else { return FFmpegSettings() }
        return (try? JSONDecoder().decode(FFmpegSettings.self, from: data)) ?? FFmpegSettings()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Where a result goes and what it is called. Never overwrites: a name that exists (or is
/// the input, or is already promised to another job) gets `-2`, `-3`... before the extension.
public enum OutputNaming {
    /// - Parameters:
    ///   - moviesFolder: `~/Movies` (injectable for tests).
    ///   - isTaken: whether a path is unavailable (exists on disk or reserved by a queued job).
    public static func output(for inputs: [String], preset: Preset, values: PresetValues, settings: FFmpegSettings,
                              moviesFolder: String = (NSHomeDirectory() as NSString).appendingPathComponent("Movies"),
                              isTaken: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let input = inputs.first ?? ""
        let url = URL(fileURLWithPath: input)
        let dir: String
        switch settings.outputFolder {
        case .same: dir = url.deletingLastPathComponent().path
        case .movies: dir = moviesFolder
        case .custom:
            let custom = (settings.customFolder as NSString).expandingTildeInPath
            dir = custom.isEmpty ? url.deletingLastPathComponent().path : custom
        }
        let name = url.deletingPathExtension().lastPathComponent
        let suffix = settings.namingSuffix.replacingOccurrences(of: "{preset}", with: preset.suffix)
            .replacingOccurrences(of: "/", with: "-")
        let ext = outputExtension(preset: preset, values: values, input: input)
        let base = (dir as NSString).appendingPathComponent(name + suffix)
        let inputs = Set(inputs.map { URL(fileURLWithPath: $0).standardizedFileURL.path })

        func candidate(_ n: Int) -> String {
            let stem = n == 1 ? base : "\(base)-\(n)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var n = 1
        while true {
            let path = candidate(n)
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            if !inputs.contains(standard), !isTaken(path) { return path }
            n += 1
        }
    }

    public static func outputExtension(preset: Preset, values: PresetValues, input: String) -> String {
        switch preset.output {
        case .fixed(let ext): return ext
        case .field(let field): return values[field]
        case .input(let fallback):
            let ext = URL(fileURLWithPath: input).pathExtension.lowercased()
            return ext.isEmpty ? fallback : ext
        }
    }
}
