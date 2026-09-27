import Foundation

/// One assembled invocation. `argv` is handed to `Process` as is; nothing is ever run
/// through a shell.
public struct Command: Equatable, Sendable {
    public var argv: [String]
    public var output: String
    /// For multi-input presets: the concat demuxer's list file and its contents, which the
    /// runner writes before starting ffmpeg.
    public var listFile: (path: String, contents: String)?

    public static func == (a: Command, b: Command) -> Bool {
        a.argv == b.argv && a.output == b.output && a.listFile?.path == b.listFile?.path
            && a.listFile?.contents == b.listFile?.contents
    }

    /// Copy/paste-able shell rendering, for the preview line only. The binary is shown by
    /// name (`ffmpeg`, found on PATH), not by where it was resolved.
    public var display: String {
        guard let first = argv.first else { return "" }
        return ([(first as NSString).lastPathComponent] + argv.dropFirst()).map(Self.quoted).joined(separator: " ")
    }

    public static func quoted(_ arg: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./:=+%,@")
        if !arg.isEmpty && arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case noInput
    case tooManyInputs(String)
    case invalid(field: String, reason: String)
    case unknownOption(field: String, value: String)
    case missingEncoder(String)

    public var description: String {
        switch self {
        case .noInput: return "no input file"
        case .tooManyInputs(let preset): return "\(preset) takes one input file"
        case let .invalid(field, reason): return "\(field): \(reason)"
        case let .unknownOption(field, value): return "\(field): \(value) is not one of the choices"
        case .missingEncoder(let name): return "this ffmpeg has no \(name) encoder (choose another option)"
        }
    }
}

/// Turns a preset, its form values and the input file(s) into argv:
///
///     ffmpeg -hide_banner -nostdin -n <inputArgs> -i <input>... <args> <output>
///
/// `-n` makes ffmpeg refuse to overwrite; `OutputNaming` has already picked a free name, so
/// this only guards against a file appearing in between. `{input}`, `{output}`, `{dir}`,
/// `{name}` and `{ext}` (of the first input) and every field id are substituted inside
/// arguments. Pure; fully tested.
public enum CommandBuilder {
    public static let fixedFlags = ["-hide_banner", "-nostdin", "-n"]

    /// `encoders`: what this ffmpeg can encode with; nil skips the check.
    public static func build(_ preset: Preset, values: PresetValues, inputs: [String], output: String,
                             ffmpeg: String = "ffmpeg", listFile: String? = nil,
                             encoders: Set<String>? = nil) throws -> Command {
        guard let first = inputs.first, !first.isEmpty else { throw CommandError.noInput }
        if !preset.multiInput, inputs.count > 1 { throw CommandError.tooManyInputs(preset.title) }
        try validate(preset, values: values)

        let tokens = self.tokens(preset: preset, values: values, input: first, output: output)
        var argv = [ffmpeg] + fixedFlags
        argv += expand(preset.inputArgs, preset: preset, values: values, tokens: tokens)
        var list: (path: String, contents: String)?
        if preset.multiInput {
            let path = listFile ?? ((output as NSString).deletingPathExtension + ".concat.txt")
            list = (path, concatList(inputs))
            argv += ["-f", "concat", "-safe", "0", "-i", path]
        } else {
            argv += ["-i", first]
        }
        argv += expand(preset.args, preset: preset, values: values, tokens: tokens)
        argv.append(output)
        if let encoders, let missing = Encoders.required(by: argv).first(where: { !encoders.contains($0) }) {
            throw CommandError.missingEncoder(missing)
        }
        return Command(argv: argv, output: output, listFile: list)
    }

    /// Token values for substitution: the path pieces plus every field's value.
    static func tokens(preset: Preset, values: PresetValues, input: String, output: String) -> [String: String] {
        var tokens: [String: String] = [:]
        for field in preset.fields { tokens[field.id] = values[field.id] }
        let url = URL(fileURLWithPath: input)
        tokens["input"] = input
        tokens["output"] = output
        tokens["dir"] = url.deletingLastPathComponent().path
        tokens["name"] = url.deletingPathExtension().lastPathComponent
        tokens["ext"] = url.pathExtension
        return tokens
    }

    static func expand(_ template: [TemplateArg], preset: Preset, values: PresetValues, tokens: [String: String]) -> [String] {
        template.flatMap { arg -> [String] in
            switch arg {
            case .arg(let s):
                return [substitute(s, tokens)]
            case let .when(field, args):
                return values[field].isEmpty ? [] : args.map { substitute($0, tokens) }
            case .option(let field):
                return (preset.field(field)?.option(values[field])?.args ?? []).map { substitute($0, tokens) }
            }
        }
    }

    /// Replaces `{key}` with `tokens[key]`; unknown `{...}` is left alone.
    public static func substitute(_ string: String, _ tokens: [String: String]) -> String {
        guard string.contains("{") else { return string }
        var result = ""
        var rest = Substring(string)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                result += rest[open...]
                rest = rest[rest.endIndex...]
                break
            }
            let key = String(rest[rest.index(after: open)..<close])
            if let value = tokens[key] { result += value } else { result += rest[open...close] }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// The concat demuxer's list: one `file '<path>'` line per input, quotes escaped the
    /// demuxer's way (`'\''`).
    public static func concatList(_ inputs: [String]) -> String {
        inputs.map { "file '" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: "\n") + "\n"
    }

    /// Checks select values are choices and text fields hold what they claim (times, sizes).
    /// Hidden fields (see `PresetField.visibleWhen`) are not checked.
    public static func validate(_ preset: Preset, values: PresetValues) throws {
        for field in preset.fields where preset.isVisible(field, values: values) {
            let value = values[field.id]
            switch field.kind {
            case .select:
                guard field.option(value) != nil else { throw CommandError.unknownOption(field: field.id, value: value) }
            case .text:
                if value.isEmpty {
                    if field.required { throw CommandError.invalid(field: field.id, reason: "required") }
                    continue
                }
                switch field.format {
                case .free: break
                case .time:
                    guard TimeFormat.seconds(value) != nil else {
                        throw CommandError.invalid(field: field.id, reason: "\(value) is not a time (00:00:05 or 5)")
                    }
                case .size:
                    guard isSize(value) else {
                        throw CommandError.invalid(field: field.id, reason: "\(value) is not width:height")
                    }
                }
            }
        }
    }

    /// `1280:720`, `1280:-2`, `-2:720`.
    static func isSize(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            guard let n = Int(part) else { return false }
            return n > 0 || n == -1 || n == -2
        } && !parts.allSatisfy { (Int($0) ?? 0) < 0 }
    }
}

/// ffmpeg time syntax: `SS[.m]`, `MM:SS[.m]` or `HH:MM:SS[.m]`.
public enum TimeFormat {
    public static func seconds(_ string: String) -> Double? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("-") else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            guard !part.isEmpty, let v = last ? Double(part) : Double(Int(part) ?? -1), v >= 0,
                  part.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
            if !last, parts.count > 1, i > 0, v >= 60 { return nil }
            total = total * 60 + v
        }
        if parts.count > 1, let lastValue = Double(parts.last!), lastValue >= 60 { return nil }
        return total
    }

    /// `83.4` -> `1:23`, `3723` -> `1:02:03`.
    public static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
