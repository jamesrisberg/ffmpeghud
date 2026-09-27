import Combine
import Foundation

/// One ffmpeg run: what it does, where it writes, and how far it got.
public struct Job: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable { case queued, running, succeeded, failed, cancelled }

    public let id: Int
    public var presetID: String
    public var presetTitle: String
    public var inputs: [String]
    public var output: String
    public var command: Command
    public var state: State = .queued
    /// 0...1 when the output's length is known, else nil (indeterminate).
    public var fraction: Double?
    /// Seconds of output written so far (`time=`).
    public var written: Double = 0
    public var expectedDuration: Double?
    public var speed: Double?
    /// ffmpeg's non-status stderr lines, last `logLimit`.
    public var log: [String] = []
    /// Why it failed (the last lines ffmpeg printed), for the errors disclosure.
    public var error: String?
    /// Whether the original went to the Trash afterwards (`keepOriginal` off).
    public var trashedOriginal = false
    public var createdAt = Date()
    public var startedAt: Date?
    public var finishedAt: Date?

    public static let logLimit = 200

    public var isActive: Bool { state == .queued || state == .running }
    public var inputName: String { URL(fileURLWithPath: inputs.first ?? "").lastPathComponent }
    public var outputName: String { URL(fileURLWithPath: output).lastPathComponent }

    public var json: [String: Any] {
        var d: [String: Any] = ["id": id, "preset": presetID, "title": presetTitle, "inputs": inputs,
                                "output": output, "state": state.rawValue, "argv": command.argv,
                                "written": (written * 100).rounded() / 100]
        if let fraction { d["progress"] = (fraction * 1000).rounded() / 1000 }
        if let expectedDuration { d["duration"] = expectedDuration }
        if let error { d["error"] = error }
        if trashedOriginal { d["trashedOriginal"] = true }
        let iso = ISO8601DateFormatter()
        d["created"] = iso.string(from: createdAt)
        if let startedAt { d["started"] = iso.string(from: startedAt) }
        if let finishedAt { d["finished"] = iso.string(from: finishedAt) }
        return d
    }
}

public enum JobError: Error, Equatable, CustomStringConvertible {
    case missingFFmpeg
    case missingInput(String)
    case outputExists(String)
    case command(CommandError)

    public var description: String {
        switch self {
        case .missingFFmpeg: return "ffmpeg is not installed (brew install ffmpeg)"
        case .missingInput(let path): return "no such file: \(path)"
        case .outputExists(let path): return "\(path) exists; ffmpegHUD never overwrites"
        case .command(let error): return error.description
        }
    }
}

/// The jobs list: queues, runs up to `concurrentJobs` at once, reports progress, cancels.
/// Newest job first.
@MainActor
public final class JobQueue: ObservableObject {
    @Published public private(set) var jobs: [Job] = []
    /// Called after every change (state events, badge).
    public var onChange: (() -> Void)?

    public var settings: FFmpegSettings
    private let ffmpeg: String?
    private let ffprobe: String?
    private let moviesFolder: String
    private let trash: (URL) throws -> Void
    /// What this ffmpeg can encode with (loaded in the background at start); nil until known.
    @Published public private(set) var encoders: Set<String>?
    private var processes: [Int: FFmpegProcess] = [:]
    private var nextID = 1

    public init(settings: FFmpegSettings = FFmpegSettings(),
                ffmpeg: String? = Executables.path("ffmpeg"),
                ffprobe: String? = Executables.path("ffprobe"),
                moviesFolder: String = (NSHomeDirectory() as NSString).appendingPathComponent("Movies"),
                trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.settings = settings
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.moviesFolder = moviesFolder
        self.trash = trash
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Encoders.load(ffmpeg: ffmpeg)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.encoders = found } }
        }
    }

    /// Whether a select option can run here (true while the encoder list is unknown).
    public func isAvailable(_ option: PresetOption) -> Bool {
        guard let encoders else { return true }
        return Encoders.required(by: option).allSatisfy(encoders.contains)
    }

    public var hasFFmpeg: Bool { ffmpeg != nil }
    public var runningCount: Int { jobs.filter { $0.state == .running }.count }
    public var activeCount: Int { jobs.filter(\.isActive).count }
    public func job(_ id: Int) -> Job? { jobs.first { $0.id == id } }

    /// Paths promised to queued or running jobs, so two jobs never pick the same name.
    private var reserved: Set<String> { Set(jobs.filter(\.isActive).map(\.output)) }

    /// The output a job would get right now (for the preview line).
    public func plannedOutput(preset: Preset, values: PresetValues, inputs: [String]) -> String {
        let reserved = self.reserved
        return OutputNaming.output(for: inputs, preset: preset, values: values, settings: settings,
                                   moviesFolder: moviesFolder,
                                   isTaken: { reserved.contains($0) || FileManager.default.fileExists(atPath: $0) })
    }

    /// The command a job would run right now (for the preview line). Throws on invalid values.
    public func plannedCommand(preset: Preset, values: PresetValues, inputs: [String]) throws -> Command {
        try CommandBuilder.build(preset, values: values, inputs: inputs,
                                 output: plannedOutput(preset: preset, values: values, inputs: inputs),
                                 ffmpeg: ffmpeg ?? "ffmpeg", listFile: Self.listFilePath(nextID), encoders: encoders)
    }

    static func listFilePath(_ id: Int) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("ffmpeghud-\(getpid())-\(id).concat.txt")
    }

    /// Queues a job and starts it when a slot is free. `duration` is the input's known length
    /// (from the drop zone's probe); without it the job probes first.
    @discardableResult
    public func enqueue(preset: Preset, values: PresetValues, inputs: [String], output explicit: String? = nil,
                        duration: Double? = nil) throws -> Job {
        guard let ffmpeg else { throw JobError.missingFFmpeg }
        let inputs = inputs.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        guard !inputs.isEmpty else { throw JobError.command(.noInput) }
        for input in inputs where !FileManager.default.fileExists(atPath: input) { throw JobError.missingInput(input) }
        let output: String
        if let explicit, !explicit.isEmpty {
            output = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath).standardizedFileURL.path
            if FileManager.default.fileExists(atPath: output) || reserved.contains(output) || inputs.contains(output) {
                throw JobError.outputExists(output)
            }
        } else {
            output = plannedOutput(preset: preset, values: values, inputs: inputs)
        }
        let id = nextID
        let command: Command
        do {
            command = try CommandBuilder.build(preset, values: values, inputs: inputs, output: output, ffmpeg: ffmpeg,
                                               listFile: Self.listFilePath(id), encoders: encoders)
        } catch let error as CommandError {
            throw JobError.command(error)
        }
        nextID += 1
        var job = Job(id: id, presetID: preset.id, presetTitle: preset.title, inputs: inputs, output: output, command: command)
        if let duration, inputs.count == 1 {
            job.expectedDuration = ProgressParser.expectedDuration(total: duration, preset: preset, values: values)
            expectedKnown.insert(id)
        }
        jobs.insert(job, at: 0)
        presets[id] = (preset, values)
        changed()
        pump()
        return self.job(id) ?? job
    }

    private var presets: [Int: (Preset, PresetValues)] = [:]
    private var expectedKnown: Set<Int> = []

    /// Cancels a queued or running job; its partial output is removed.
    @discardableResult
    public func cancel(_ id: Int) -> Bool {
        guard let job = job(id), job.isActive else { return false }
        if job.state == .queued {
            update(id) { $0.state = .cancelled; $0.finishedAt = Date() }
            changed()
            return true
        }
        if let process = processes[id] {
            process.cancel()
        } else {
            // Still probing: never launched, nothing to clean up.
            update(id) { $0.state = .cancelled; $0.finishedAt = Date() }
            presets[id] = nil
            changed()
            pump()
        }
        return true
    }

    public func cancelAll() { for job in jobs where job.isActive { cancel(job.id) } }

    /// For quitting: stops every ffmpeg synchronously and removes partial outputs and list
    /// files, since the app will not be around for the usual completion. Blocks briefly.
    public func shutdown() {
        for job in jobs where job.isActive {
            if let process = processes[job.id] {
                process.stopAndWait()
                try? FileManager.default.removeItem(atPath: job.output)
            }
            if let list = job.command.listFile { try? FileManager.default.removeItem(atPath: list.path) }
            update(job.id) { $0.state = .cancelled; $0.finishedAt = Date() }
        }
        processes.removeAll()
        changed()
    }

    /// Drops finished jobs from the list.
    public func clearFinished() {
        jobs.removeAll { !$0.isActive }
        changed()
    }

    // MARK: - Running

    private func pump() {
        while runningCount < max(1, settings.concurrentJobs),
              let next = jobs.last(where: { $0.state == .queued }) {
            start(next.id)
        }
    }

    private func start(_ id: Int) {
        update(id) { $0.state = .running; $0.startedAt = Date() }
        changed()
        guard let job = job(id) else { return }
        if expectedKnown.contains(id) || ffprobe == nil {
            launch(id)
            return
        }
        // Probe for the length (every input, for a join) off the main thread.
        let inputs = job.inputs
        let ffprobe = self.ffprobe
        DispatchQueue.global(qos: .userInitiated).async {
            var total: Double? = 0
            for input in inputs {
                if case .success(let info) = Probe.run(input, ffprobe: ffprobe), let d = info.duration, let t = total {
                    total = t + d
                } else {
                    total = nil
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let (preset, values) = self.presets[id] else { return }
                    self.update(id) { $0.expectedDuration = ProgressParser.expectedDuration(total: total, preset: preset, values: values) }
                    // Cancelled while probing.
                    guard self.job(id)?.state == .running else { return }
                    self.launch(id)
                }
            }
        }
    }

    private func launch(_ id: Int) {
        guard let job = job(id) else { return }
        do {
            try FileManager.default.createDirectory(atPath: (job.output as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            if let list = job.command.listFile {
                try list.contents.write(toFile: list.path, atomically: true, encoding: .utf8)
            }
        } catch {
            finish(id, status: -1, cancelled: false, message: "could not prepare the output: \(error.localizedDescription)")
            return
        }
        let process = FFmpegProcess(argv: job.command.argv)
        processes[id] = process
        do {
            try process.start(onLine: { [weak self] line in
                MainActor.assumeIsolated { self?.handle(line, job: id) }
            }, done: { [weak self] status, cancelled in
                MainActor.assumeIsolated { self?.finish(id, status: status, cancelled: cancelled) }
            })
        } catch {
            processes[id] = nil
            finish(id, status: -1, cancelled: false, message: "\(error)")
        }
    }

    private func handle(_ line: String, job id: Int) {
        if ProgressParser.isStatus(line) {
            guard let time = ProgressParser.time(in: line) else { return }
            update(id) { job in
                job.written = time
                job.speed = ProgressParser.speed(in: line)
                job.fraction = ProgressParser.fraction(time: time, expected: job.expectedDuration)
            }
        } else {
            update(id) { job in
                job.log.append(line)
                if job.log.count > Job.logLimit { job.log.removeFirst(job.log.count - Job.logLimit) }
            }
        }
    }

    private func finish(_ id: Int, status: Int32, cancelled: Bool, message: String? = nil) {
        processes[id] = nil
        guard let job = job(id) else { return }
        if let list = job.command.listFile { try? FileManager.default.removeItem(atPath: list.path) }
        if status == 0, !cancelled {
            update(id) { $0.state = .succeeded; $0.fraction = 1 }
            if !settings.keepOriginal { trashOriginals(of: id) }
        } else {
            // The output did not exist before (names are never reused), so what is there is partial.
            try? FileManager.default.removeItem(atPath: job.output)
            update(id) { job in
                job.state = cancelled ? .cancelled : .failed
                if !cancelled {
                    job.error = message ?? Self.errorSummary(job.log, status: status)
                }
            }
        }
        update(id) { $0.finishedAt = Date() }
        presets[id] = nil
        expectedKnown.remove(id)
        changed()
        pump()
    }

    /// The last few lines ffmpeg printed, which is where it says what went wrong.
    nonisolated static func errorSummary(_ log: [String], status: Int32) -> String {
        let tail = log.suffix(4).joined(separator: "\n")
        return tail.isEmpty ? "ffmpeg exited with status \(status)" : tail
    }

    /// `keepOriginal` off: the inputs go to the Trash, unless another job still needs them.
    private func trashOriginals(of id: Int) {
        guard let job = job(id) else { return }
        let stillNeeded = Set(jobs.filter { $0.isActive && $0.id != id }.flatMap(\.inputs))
        var trashed = false
        for input in job.inputs where !stillNeeded.contains(input) {
            if (try? trash(URL(fileURLWithPath: input))) != nil { trashed = true }
        }
        update(id) { $0.trashedOriginal = trashed }
    }

    private func update(_ id: Int, _ body: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }

    private func changed() { onChange?() }
}
