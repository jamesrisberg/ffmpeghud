import AppKit
import ffmpegHUDKit
import HUDKit

/// ffmpegHUD's side of the MacHUD contract: serves the control socket at
/// `~/Library/Application Support/MacHUD/sockets/ffmpeghud.sock` through HUDKit's router.
/// See docs/CONTRACT.md for the verbs.
@MainActor
final class ControlHost: HUDPanelHost {
    static let panelID = "tools"
    static let actions = ["show", "hide", "toggle", "drop", "run", "jobs", "cancel", "presets", "snapshot"]
    static let verbs = ["show", "hide", "toggle", "frame", "mode", "drop", "run", "jobs", "cancel", "presets"]

    /// Used when running outside a bundle (e.g. `swift run`); mirrors Sources/ffmpegHUD/Resources/machud.json.
    static let builtinManifest = HUDManifest(id: "xyz.machud.ffmpeghud", name: "ffmpegHUD", socket: "ffmpeghud", panels: [
        HUDManifest.Panel(id: panelID, title: "ffmpeg", symbol: "film.stack",
                          defaultSize: HUDSize(PanelController.fullSize), compactSize: HUDSize(PanelController.compactSize),
                          capabilities: ["acceptsFileDrop"], verbs: verbs, settingsSchema: "settings.json", kind: .hover, order: 3),
    ])

    /// `action run` arguments that are not preset fields.
    static let runReserved: Set<String> = ["preset", "input", "inputs", "output", "show", "_", "name"]

    let manifest: HUDManifest
    let server: HUDSocketServer
    private(set) var router: HUDControlRouter!
    private let model: AppModel
    private let panel: PanelController
    private var lastPublished: String?
    private var routerWillPublish = false

    init(model: AppModel, panel: PanelController) {
        self.model = model
        self.panel = panel
        manifest = HUDManifest.main ?? Self.builtinManifest
        server = HUDSocketServer(path: HUDSocket.path(for: AppEnvironment.socketName(default: manifest.socket)),
                                 label: "ffmpeghud.socket")
        router = HUDControlRouter(host: self, server: server, manifest: manifest)
    }

    func start() {
        router.install()
        if !server.start() { NSLog("ffmpegHUD: control socket failed to start at %@", server.path) }
        panel.onStateChange = { [weak self] in self?.publishIfChanged() }
        model.onChange = { [weak self] in self?.publishIfChanged() }
    }

    func stop() { server.stop() }

    /// Pushes `state` to subscribers when anything they can see changed. Progress ticks do not
    /// change the badge or status, so they are not pushed.
    func publishIfChanged() {
        let signature = panelStates.map { "\($0.visible)|\($0.mode)|\($0.badge ?? "")|\($0.status ?? "")" }.joined()
        guard signature != lastPublished else { return }
        lastPublished = signature
        if !routerWillPublish { router.publishState() }
    }

    private func routed(_ body: () throws -> Void) rethrows {
        routerWillPublish = true
        defer { routerWillPublish = false }
        try body()
        publishIfChanged()
    }

    // MARK: - HUDPanelHost

    var panelDescriptors: [HUDManifest.Panel] { manifest.panels }

    /// `badge`: running jobs (absent when none). `status`: what is happening, else the dropped file.
    var panelStates: [HUDPanelState] {
        let running = model.queue.runningCount
        let queued = model.queue.jobs.filter { $0.state == .queued }.count
        var status: String?
        if running > 0 {
            status = queued > 0 ? "\(running) running, \(queued) waiting" : "\(running) running"
        } else if let input = model.primaryInput {
            status = input.lastPathComponent
        }
        return [HUDPanelState(id: Self.panelID, visible: panel.isShown, mode: panel.mode,
                              badge: running > 0 ? String(running) : nil, status: status)]
    }

    private func check(_ id: String) throws {
        guard id == Self.panelID else { throw HUDControlError.noSuchPanel(id) }
    }

    /// MacHUD shows a hover panel while the pointer is over its dock button, so a socket show
    /// never takes focus; the panel becomes key when clicked. Summon restores the last mode.
    func showPanel(_ id: String) throws { try check(id); routed { panel.show(takeFocus: false) } }
    func togglePanel(_ id: String) throws { try check(id); routed { panel.toggle(takeFocus: false) } }
    func hidePanel(_ id: String) throws { try check(id); routed { panel.hide() } }

    /// MacHUD's dock: `from=`/`anchor=` slide out of the button to the assigned frame,
    /// `reason=hover` is a 0.08 s show that never takes key, `click`/`summon` make the panel key.
    func showPanel(_ id: String, options: [String: String]) throws {
        try check(id); routed { panel.show(HUDPanelTransition(options)) }
    }

    /// `to=<edge>` slides back toward the dock in 0.1 s.
    func hidePanel(_ id: String, options: [String: String]) throws {
        try check(id); routed { panel.hide(HUDPanelTransition(options)) }
    }

    func togglePanel(_ id: String, options: [String: String]) throws {
        try check(id); routed { panel.toggle(HUDPanelTransition(options)) }
    }

    func setPanelFrame(_ id: String, frame: CGRect) throws {
        try check(id)
        guard frame.width >= 40, frame.height >= 40 else { throw HUDControlError.invalid("frame too small") }
        routed { panel.setFrame(frame) }
    }

    func setPanelMode(_ id: String, mode: HUDPanelMode) throws {
        try setPanelMode(id, mode: mode, options: HUDPanelModeOptions())
    }

    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        try check(id)
        routed { panel.setMode(mode, options: options) }
    }

    // MARK: Settings

    func settings() -> [String: Any] { model.settings.json }

    func updateSettings(_ values: [String: String]) throws {
        do {
            try model.updateSettings(values)
        } catch let error as FFmpegSettings.SettingsError {
            throw HUDControlError.invalid(error.description)
        }
    }

    // MARK: Actions

    private static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    /// Absolute, tilde-expanded, standardized.
    static func absolute(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        do {
            switch name {
            case "show", "hide", "toggle":
                switch name {
                case "show": panel.show(takeFocus: false)
                case "hide": panel.hide()
                default: panel.toggle(takeFocus: false)
                }
                publishIfChanged()
                done(["ok": true, "visible": panel.isShown])

            case "drop":
                // `paths=` pipe-separated percent-encoded (HUDDrop; `file://` URLs and plain
                // paths too); `path=` one raw path.
                var paths = HUDDrop.urls(from: args).map(\.path)
                if let path = args["path"], !path.isEmpty { paths.append(path) }
                guard !paths.isEmpty else { throw HUDControlError.invalid("paths= required (pipe-separated, percent-encoded)") }
                let accepted = model.drop(paths.map { URL(fileURLWithPath: Self.absolute($0)) })
                guard !accepted.isEmpty else { throw HUDControlError.invalid("no such file: \(paths.joined(separator: ", "))") }
                if args["show"].map(Self.flag) ?? true {
                    if panel.mode == .compact { panel.setMode(.full) }
                    panel.show(takeFocus: false)
                }
                publishIfChanged()
                done(["ok": true, "files": accepted.map(\.path)])

            case "run":
                guard let presetID = args["preset"], !presetID.isEmpty else {
                    throw HUDControlError.invalid("preset= required (\(PresetCatalog.all.map(\.id).joined(separator: ", ")))")
                }
                var inputs = args["inputs"].map { HUDDrop.decode($0).map(\.path) } ?? []
                if let input = args["input"], !input.isEmpty { inputs.insert(input, at: 0) }
                if inputs.isEmpty { inputs = model.inputs.map(\.path) }
                guard !inputs.isEmpty else { throw HUDControlError.invalid("input= required (or drop a file first)") }
                let overrides = args.filter { !Self.runReserved.contains($0.key) }
                let job = try model.run(presetID: presetID, inputs: inputs.map(Self.absolute), overrides: overrides,
                                        output: args["output"].map(Self.absolute))
                if Self.flag(args["show"]) { panel.show(takeFocus: false) }
                publishIfChanged()
                done(["ok": true, "job": job.json])

            case "jobs":
                let jobs = model.queue.jobs
                let filtered = args["id"].flatMap(Int.init).map { id in jobs.filter { $0.id == id } } ?? jobs
                done(["ok": true, "running": model.queue.runningCount, "count": filtered.count,
                      "jobs": filtered.map(\.json)])

            case "cancel":
                if Self.flag(args["all"]) {
                    model.queue.cancelAll()
                    done(["ok": true])
                    return
                }
                guard let id = args["id"].flatMap(Int.init) else { throw HUDControlError.invalid("id= required (or all=1)") }
                guard model.queue.cancel(id) else { throw HUDControlError.invalid("job \(id) is not queued or running") }
                done(["ok": true, "id": id])

            case "presets":
                var result: [String: Any] = ["ok": true, "presets": model.visiblePresets.map(\.json)]
                if let input = model.primaryInput {
                    var drop: [String: Any] = ["path": input.path]
                    if let info = model.primaryInfo { drop["info"] = info.json }
                    result["input"] = drop
                }
                done(result)

            case "snapshot":
                // A PNG of the panel as it is now (for docs and checks without Screen Recording).
                guard let path = args["path"], !path.isEmpty else { throw HUDControlError.invalid("path= required") }
                let url = URL(fileURLWithPath: Self.absolute(path))
                guard panel.writeSnapshot(to: url) else { throw HUDControlError.invalid("snapshot failed") }
                done(["ok": true, "path": url.path])

            default:
                throw HUDControlError.invalid("unknown action \(name) (\(Self.actions.joined(separator: ", ")))")
            }
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    }

    func quit() { NSApp.terminate(nil) }
}
