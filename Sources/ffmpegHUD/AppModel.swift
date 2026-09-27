import AppKit
import Combine
import ffmpegHUDKit

/// The panel's state: the dropped file(s) and what ffprobe said, the chosen preset and its
/// form, recent presets, settings, and the job queue.
@MainActor
final class AppModel: ObservableObject {
    enum ProbeState: Equatable {
        case probing
        case ready(MediaInfo)
        case failed(String)
    }

    struct Message: Equatable {
        var text: String
        var isError: Bool
    }

    @Published private(set) var inputs: [URL] = []
    @Published private(set) var probes: [String: ProbeState] = [:]
    @Published private(set) var selectedID: String
    @Published var values: PresetValues
    @Published var search = ""
    @Published private(set) var recents: [String]
    @Published var isCompact = false
    @Published var isDropTargeted = false
    @Published private(set) var message: Message?
    @Published private(set) var settings: FFmpegSettings
    @Published var expandedErrors: Set<Int> = []

    let queue: JobQueue
    let settingsURL: URL
    private var cancellables: Set<AnyCancellable> = []
    private var messageClear: DispatchWorkItem?
    /// Called when the dropped file or the job list changes (for `state` events).
    var onChange: (() -> Void)?

    static let recentsKey = "RecentPresets"
    static let lastPresetKey = "LastPreset"

    init(settingsURL: URL, queue: JobQueue? = nil, defaults: KeyValueStore = AppEnvironment.store) {
        self.settingsURL = settingsURL
        let settings = FFmpegSettings.load(from: settingsURL)
        self.settings = settings
        self.queue = queue ?? JobQueue(settings: settings)
        self.queue.settings = settings
        recents = defaults.stringArray(forKey: Self.recentsKey) ?? []
        let last = defaults.string(forKey: Self.lastPresetKey).flatMap(PresetCatalog.preset) ?? PresetCatalog.all[0]
        selectedID = last.id
        values = PresetValues(preset: last)
        self.defaults = defaults
        // Re-render when jobs progress, and tell the socket.
        self.queue.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.queue.onChange = { [weak self] in self?.onChange?() }
    }

    private let defaults: KeyValueStore

    // MARK: - Presets

    var preset: Preset { PresetCatalog.preset(selectedID) ?? PresetCatalog.all[0] }

    /// Recently used first, then the catalog, filtered by the search field.
    var visiblePresets: [Preset] { Recents.ordered(PresetCatalog.all, recents: recents, query: search) }

    func select(_ id: String) {
        guard let preset = PresetCatalog.preset(id), id != selectedID else { return }
        selectedID = id
        values = PresetValues(preset: preset)
        defaults.set(id, forKey: Self.lastPresetKey)
    }

    func setValue(_ value: String, for field: String) { values[field] = value }

    /// Whether the form's current choice needs an encoder this ffmpeg lacks.
    func isAvailable(_ option: PresetOption) -> Bool { queue.isAvailable(option) }

    private func touchRecent(_ id: String) {
        recents = Recents.touch(id, in: recents)
        defaults.set(recents, forKey: Self.recentsKey)
    }

    // MARK: - Input

    var primaryInput: URL? { inputs.first }
    var primaryProbe: ProbeState? { primaryInput.flatMap { probes[$0.path] } }
    var primaryInfo: MediaInfo? { if case .ready(let info)? = primaryProbe { return info }; return nil }

    /// Takes dropped files (folders and missing paths are skipped) and probes each.
    @discardableResult
    func drop(_ urls: [URL]) -> [URL] {
        var isDir: ObjCBool = false
        let files = urls.map(\.standardizedFileURL).filter {
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && !isDir.boolValue
        }
        guard !files.isEmpty else {
            show("Drop a video or audio file", error: true)
            return []
        }
        inputs = files
        probes = [:]
        for file in files { probe(file) }
        if files.count > 1, !preset.multiInput, search.isEmpty {
            show("\(files.count) files: Run makes one job per file (Join clips joins them)")
        }
        onChange?()
        return files
    }

    func clearInput() {
        inputs = []
        probes = [:]
        onChange?()
    }

    private func probe(_ url: URL) {
        probes[url.path] = .probing
        Probe.run(url.path) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.inputs.contains(url) else { return }
                switch result {
                case .success(let info): self.probes[url.path] = .ready(info)
                case .failure(let error): self.probes[url.path] = .failed(error.description)
                }
                self.onChange?()
            }
        }
    }

    // MARK: - Command

    /// The preview: the command Run would start for the first file (or a stand-in before a
    /// drop), or why it cannot run.
    var preview: Result<Command, CommandError> {
        let inputs = self.inputs.isEmpty ? ["input.mp4"] : preset.multiInput ? self.inputs.map(\.path) : [self.inputs[0].path]
        do {
            if self.inputs.isEmpty {
                let ext = OutputNaming.outputExtension(preset: preset, values: values, input: "input.mp4")
                let suffix = settings.namingSuffix.replacingOccurrences(of: "{preset}", with: preset.suffix)
                return .success(try CommandBuilder.build(preset, values: values, inputs: inputs,
                                                         output: "input\(suffix).\(ext)", encoders: queue.encoders))
            }
            return .success(try queue.plannedCommand(preset: preset, values: values, inputs: inputs))
        } catch let error as CommandError {
            return .failure(error)
        } catch {
            return .failure(.invalid(field: "command", reason: "\(error)"))
        }
    }

    var canRun: Bool {
        guard !inputs.isEmpty, queue.hasFFmpeg else { return false }
        if case .failure = preview { return false }
        return true
    }

    /// Starts the preset on the dropped file(s): one job, or one per file for single-input presets.
    @discardableResult
    func run() -> [Job] {
        guard !inputs.isEmpty else { show("Drop a file first", error: true); return [] }
        let groups = preset.multiInput ? [inputs] : inputs.map { [$0] }
        var jobs: [Job] = []
        for group in groups {
            do {
                let duration: Double? = group.count == 1 ? info(group[0])?.duration : nil
                jobs.append(try queue.enqueue(preset: preset, values: values, inputs: group.map(\.path), duration: duration))
            } catch {
                show("\(error)", error: true)
                break
            }
        }
        if !jobs.isEmpty { touchRecent(preset.id) }
        return jobs
    }

    /// Runs a preset from the socket, independent of the dropped file.
    func run(presetID: String, inputs: [String], overrides: [String: String], output: String?) throws -> Job {
        guard let preset = PresetCatalog.preset(presetID) else { throw RunError.unknownPreset(presetID) }
        let values = PresetValues(preset: preset).applying(overrides, preset: preset)
        let job = try queue.enqueue(preset: preset, values: values, inputs: inputs, output: output,
                                    duration: inputs.count == 1 ? info(URL(fileURLWithPath: inputs[0]))?.duration : nil)
        touchRecent(preset.id)
        return job
    }

    enum RunError: Error, CustomStringConvertible {
        case unknownPreset(String)
        var description: String {
            switch self {
            case .unknownPreset(let id):
                return "no preset \(id) (\(PresetCatalog.all.map(\.id).joined(separator: ", ")))"
            }
        }
    }

    private func info(_ url: URL) -> MediaInfo? {
        if case .ready(let info)? = probes[url.standardizedFileURL.path] { return info }
        return nil
    }

    func reveal(_ job: Job) {
        let url = URL(fileURLWithPath: job.output)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    func toggleErrors(_ id: Int) {
        if expandedErrors.contains(id) { expandedErrors.remove(id) } else { expandedErrors.insert(id) }
    }

    // MARK: - Settings

    func updateSettings(_ values: [String: String]) throws {
        let updated = try settings.applying(values)
        try updated.save(to: settingsURL)
        settings = updated
        queue.settings = updated
    }

    /// Where results go right now, for the menu's Reveal Output Folder.
    var outputFolder: URL {
        switch settings.outputFolder {
        case .same: return primaryInput?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        case .movies: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        case .custom: return URL(fileURLWithPath: (settings.customFolder as NSString).expandingTildeInPath)
        }
    }

    // MARK: - Messages

    func show(_ text: String, error: Bool = false) {
        message = Message(text: text, isError: error)
        messageClear?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.message = nil }
        messageClear = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 6 : 3.5), execute: task)
    }
}
