import Foundation

/// Which encoders this ffmpeg was built with. Homebrew's ffmpeg, for one, ships without
/// libx265 and libvpx; choices needing a missing encoder are disabled in the form and
/// refused with a clear message instead of failing half-way through a job.
public enum Encoders {
    /// Parses `ffmpeg -hide_banner -encoders`: lines like ` V....D libx264   libx264 H.264 ...`
    /// after the `------` separator.
    public static func parse(_ output: String) -> Set<String> {
        var names = Set<String>()
        var pastHeader = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("---") { pastHeader = true; continue }
            guard pastHeader else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6 else { continue }
            names.insert(String(parts[1]))
        }
        return names
    }

    /// Encoders an argv asks for (`-c:v X`, `-c:a X`, `-c X`, `-codec:v X`...), except `copy`.
    public static func required(by argv: [String]) -> [String] {
        var result: [String] = []
        for (i, arg) in argv.enumerated() where i + 1 < argv.count {
            guard arg == "-c" || arg == "-codec" || arg.hasPrefix("-c:") || arg.hasPrefix("-codec:") else { continue }
            let name = argv[i + 1]
            if name != "copy", !result.contains(name) { result.append(name) }
        }
        return result
    }

    /// The encoders a select option needs, for greying it out.
    public static func required(by option: PresetOption) -> [String] { required(by: option.args) }

    /// Runs `ffmpeg -encoders` (synchronously; call off the main thread). nil when it cannot.
    public static func load(ffmpeg: String?) -> Set<String>? {
        guard let ffmpeg else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffmpeg)
        task.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let names = parse(String(decoding: data, as: UTF8.self))
        return task.terminationStatus == 0 && !names.isEmpty ? names : nil
    }
}
