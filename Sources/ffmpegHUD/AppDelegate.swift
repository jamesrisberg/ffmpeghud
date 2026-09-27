import AppKit
import ffmpegHUDKit
import HUDKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var control: ControlHost!
    static let toggleHotKey = HUDHotKey(key: "f", modifiers: ["control", "option"])

    func applicationDidFinishLaunching(_ notification: Notification) {
        HUDEditMenu.install(appName: "ffmpegHUD")
        model = AppModel(settingsURL: AppEnvironment.settingsURL)
        panel = PanelController(model: model)
        control = ControlHost(model: model, panel: panel)
        control.start()
        setupStatusItem()
        // While MacHUD runs, its menu hosts this one and the icon hides (HUDKit menu bar consolidation).
        control.router.menuProvider = { [weak self] in self?.statusItem?.menu }
        // menuBar.consumed is kept in <home>/menubar.json, so FFMPEGHUD_HOME isolates it too.
        HUDStatusItemPolicy.attach(statusItem, appID: control.manifest.id, store: .home(AppEnvironment.baseDirectory))
        if AppEnvironment.hotKeysEnabled {
            if HUDHotKeyCenter.shared.register(Self.toggleHotKey, onPress: { [weak self] in self?.panel.toggle() }) == nil {
                model.show("⌃⌥F is taken by another app; use the menu bar icon", error: true)
            }
        }

        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        // `--preset <id>`: start on that preset. `--drop <path>`: start with that file dropped.
        // `--run`: run the preset on it. All three are for --snapshot and demos.
        if let id = value("--preset") { model.select(id) }
        if let path = value("--drop") { model.drop([URL(fileURLWithPath: ControlHost.absolute(path))]) }
        if args.contains("--run") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.model.run() }
        }
        panel.show(takeFocus: false)

        // `--snapshot <path.png>`: write a PNG of the panel after it settles (for docs and for
        // verifying the UI without Screen Recording permission). `--snapshot-mode compact`
        // pictures the tile; `--snapshot-delay <s>` waits longer (default 2).
        if let path = value("--snapshot") {
            if value("--snapshot-mode") == "compact" { panel.setMode(.compact) }
            let delay = value("--snapshot-delay").flatMap(Double.init) ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.panel.writeSnapshot(to: URL(fileURLWithPath: path))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave ffmpeg running behind us, nor half-written files.
        model.queue.shutdown()
        control.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    // MARK: - Status item

    private enum Tag: Int { case toggle = 1, compact, cancelAll }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = HUDStatusIcon.image(fallbackSymbol: "film.stack", accessibilityDescription: "ffmpegHUD")

        let menu = NSMenu()
        menu.delegate = self
        let toggle = NSMenuItem(title: "Show ffmpegHUD", action: #selector(togglePanel), keyEquivalent: "f")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.tag = Tag.toggle.rawValue
        menu.addItem(toggle)
        let compact = NSMenuItem(title: "Compact Tile", action: #selector(toggleCompact), keyEquivalent: "")
        compact.tag = Tag.compact.rawValue
        menu.addItem(compact)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Choose Files…", action: #selector(chooseFiles), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal Output Folder", action: #selector(revealOutput), keyEquivalent: ""))
        let cancel = NSMenuItem(title: "Cancel All Jobs", action: #selector(cancelAll), keyEquivalent: "")
        cancel.tag = Tag.cancelAll.rawValue
        menu.addItem(cancel)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ffmpegHUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) && item.target == nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch Tag(rawValue: item.tag) {
            case .toggle: item.title = panel.isShown ? "Hide ffmpegHUD" : "Show ffmpegHUD"
            case .compact: item.state = panel.mode == .compact ? .on : .off
            case .cancelAll: item.isEnabled = model.queue.activeCount > 0
            case nil: break
            }
        }
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func toggleCompact() { panel.setMode(panel.mode == .compact ? .full : .compact, takeFocus: true) }
    @objc private func cancelAll() { model.queue.cancelAll() }

    @objc private func chooseFiles() {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.canChooseDirectories = false
        open.allowedContentTypes = [.movie, .audio, .image]
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK else { return }
        model.drop(open.urls)
        if panel.mode != .full { panel.setMode(.full) }
        panel.show()
    }

    @objc private func revealOutput() {
        let dir = model.outputFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
