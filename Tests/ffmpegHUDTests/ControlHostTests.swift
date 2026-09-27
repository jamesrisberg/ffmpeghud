import AppKit
@testable import ffmpegHUD
import ffmpegHUDKit
import HUDKit
import XCTest

/// The socket verbs against a real model and panel (the socket itself is not started).
@MainActor
final class ControlHostTests: XCTestCase {
    private var dir: URL!
    private var model: AppModel!
    private var panel: PanelController!
    private var control: ControlHost!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ffmpeghud-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // No preferences are written: recents and panel frames stay in memory.
        AppEnvironment.store = MemoryStore()
        model = AppModel(settingsURL: dir.appendingPathComponent("preferences.json"), defaults: AppEnvironment.store)
        panel = PanelController(model: model)
        control = ControlHost(model: model, panel: panel)
    }

    override func tearDown() async throws {
        model.queue.cancelAll()
        panel.panel.orderOut(nil)
        control = nil
        panel = nil
        model = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func send(_ verb: String, _ args: [String: String]) -> [String: Any] {
        var response: [String: Any] = [:]
        control.router.handle(verb, args: args) { response = $0 }
        return response
    }

    private func file(_ name: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try Data("not really a video".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    func testHelloAndState() {
        let hello = send("hello", [:])
        XCTAssertEqual(hello["app"] as? String, "xyz.machud.ffmpeghud")
        let panels = hello["panels"] as? [[String: Any]]
        XCTAssertEqual(panels?.first?["id"] as? String, "tools")
        XCTAssertEqual(panels?.first?["kind"] as? String, "hover")
        let state = send("state", [:])["panels"] as? [[String: Any]]
        XCTAssertNil(state?.first?["badge"], "no badge while nothing runs")
    }

    func testDropDecodesPipeSeparatedPercentEncodedPaths() throws {
        let a = try file("my clip|one.mov")
        let b = try file("100% two.mov")
        let response = send("action", ["name": "drop", "paths": HUDDrop.encode([a, b].map(URL.init(fileURLWithPath:))), "show": "0"])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertEqual(response["files"] as? [String], [a, b])
        XCTAssertEqual(model.inputs.map(\.path), [a, b])
        XCTAssertFalse(panel.isShown, "show=0 leaves the panel hidden")
        let state = send("state", [:])["panels"] as? [[String: Any]]
        XCTAssertEqual(state?.first?["status"] as? String, "my clip|one.mov")
    }

    func testDropShowsAndRestoresFullMode() throws {
        let a = try file("a.mov")
        panel.setMode(.compact)
        panel.hide()
        XCTAssertEqual(send("action", ["_": "drop", "paths": HUDDrop.encode([a].map(URL.init(fileURLWithPath:)))])["ok"] as? Bool, true)
        XCTAssertTrue(panel.isShown)
        XCTAssertEqual(panel.mode, .full)
    }

    func testDropAcceptsFileURLsAndPlainPaths() throws {
        let a = try file("plain one.mov")
        let b = try file("url two.mov")
        let payload = a + "|" + URL(fileURLWithPath: b).absoluteString
        let response = send("action", ["name": "drop", "paths": payload, "show": "0"])
        XCTAssertEqual(response["files"] as? [String], [a, b], "\(response)")
    }

    func testDockTransitionsThroughRouter() throws {
        func panelCmd(_ args: [String: String]) -> [String: Any] { send("panel", ["id": "tools"].merging(args) { $1 }) }
        // Inside the main screen's visible area, so AppKit does not push the window on-screen on a
        // small display (the CI runner's).
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let assigned = CGRect(x: (visible.minX + 40).rounded(), y: (visible.minY + 40).rounded(), width: 640, height: 500)
        XCTAssertEqual(panelCmd(["frame": "1", "x": "\(Int(assigned.minX))", "y": "\(Int(assigned.minY))", "w": "640", "h": "500"])["ok"] as? Bool, true)

        // Hover show: slides out of the bottom dock to the assigned frame, never takes key.
        let shown = panelCmd(["show": "1", "from": "bottom", "anchor": "100,0,44,44", "reason": "hover"])
        XCTAssertEqual(shown["visible"] as? Bool, true, "\(shown)")
        spin(until: panel.panel.frame == assigned)
        XCTAssertTrue(panel.panel.isVisible)
        XCTAssertFalse(panel.panel.isKeyWindow, "hover must not take key")
        XCTAssertEqual(panel.panel.frame, assigned)

        // Pointer leaves and comes straight back: the show wins over the hide in flight.
        XCTAssertEqual(panelCmd(["hide": "1", "to": "bottom"])["visible"] as? Bool, false)
        XCTAssertEqual(panelCmd(["show": "1", "from": "bottom", "anchor": "100,0,44,44", "reason": "hover"])["visible"] as? Bool, true)
        spin(until: panel.panel.frame == assigned && panel.panel.alphaValue == 1)
        XCTAssertTrue(panel.panel.isVisible, "the stale hide must not order the panel out")
        XCTAssertEqual(panel.panel.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(panel.panel.frame, assigned)

        // A hide on its own slides out, orders out and restores the rest frame.
        XCTAssertEqual(panelCmd(["hide": "1", "to": "bottom"])["visible"] as? Bool, false)
        spin(until: !panel.panel.isVisible && panel.panel.frame == assigned)
        XCTAssertFalse(panel.panel.isVisible)
        XCTAssertEqual(panel.panel.frame, assigned)

        // Without an assigned frame the panel rests next to the anchor, above a bottom dock.
        panel.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        XCTAssertNil(panel.assignedFrame, "a user resize drops MacHUD's frame")
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let button = CGRect(x: screen.midX - 22, y: screen.minY, width: 44, height: 44)
        _ = panelCmd(["show": "1", "from": "bottom", "anchor": HUDPanelTransition.formatAnchor(button), "reason": "click"])
        spin(until: abs(panel.panel.frame.midX - button.midX) < 0.5 && panel.panel.frame.minY >= button.maxY)
        XCTAssertEqual(panel.panel.frame.size, assigned.size)
        XCTAssertEqual(panel.panel.frame.midX, button.midX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(panel.panel.frame.minY, button.maxY)

        XCTAssertEqual(panelCmd(["show": "1", "from": "middle"])["ok"] as? Bool, false)
    }

    func testDockTimings() {
        XCTAssertEqual(PanelController.hoverShowDuration, 0.08)
        XCTAssertEqual(PanelController.slideHideDuration, 0.1)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes: the motions are
    /// run-loop animations, and the CI runner is slow to advance them.
    private func spin(until condition: @autoclosure () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testDropRejectsMissingFiles() {
        let response = send("action", ["name": "drop", "paths": HUDDrop.encode([dir.appendingPathComponent("nope.mov").path].map(URL.init(fileURLWithPath:)))])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(send("action", ["name": "drop"])["ok"] as? Bool, false)
    }

    func testRunValidation() throws {
        let a = try file("a.mov")
        XCTAssertEqual(send("action", ["name": "run", "input": a])["ok"] as? Bool, false, "preset= required")
        let unknown = send("action", ["name": "run", "preset": "sparkle", "input": a])
        XCTAssertTrue((unknown["error"] as? String)?.contains("no preset sparkle") == true)
        XCTAssertEqual(send("action", ["name": "run", "preset": "gif"])["ok"] as? Bool, false, "no input and nothing dropped")
        let missing = send("action", ["name": "run", "preset": "gif", "input": dir.appendingPathComponent("x.mov").path])
        XCTAssertEqual(missing["ok"] as? Bool, false)
    }

    /// Field values are checked after the ffmpeg lookup, so without ffmpeg the refusal
    /// names ffmpeg instead of the field.
    func testRunRefusesAnInvalidField() throws {
        try XCTSkipIf(Executables.path("ffmpeg") == nil, "ffmpeg is not installed")
        let a = try file("a.mov")
        let bad = send("action", ["name": "run", "preset": "trim", "input": a, "start": "soon"])
        XCTAssertTrue((bad["error"] as? String)?.contains("start") == true, "\(bad)")
    }

    func testRunQueuesAJobWithFieldOverrides() throws {
        try XCTSkipIf(Executables.path("ffmpeg") == nil, "ffmpeg is not installed")
        let a = try file("a.mov")
        let response = send("action", ["name": "run", "preset": "gif", "input": a, "fps": "10", "width": "320"])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        let job = try XCTUnwrap(response["job"] as? [String: Any])
        XCTAssertEqual(job["output"] as? String, dir.appendingPathComponent("a_gif.gif").path)
        let argv = try XCTUnwrap(job["argv"] as? [String])
        XCTAssertTrue(argv.contains("fps=10,scale=320:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"))
        let jobs = send("action", ["name": "jobs"])
        XCTAssertEqual(jobs["count"] as? Int, 1)
        XCTAssertEqual(model.recents.first, "gif", "a socket run counts as recent")
        XCTAssertEqual(send("action", ["name": "cancel"])["ok"] as? Bool, false, "id= required")
        _ = send("action", ["name": "cancel", "all": "1"])
    }

    func testPresetsAndSettings() {
        let presets = send("action", ["name": "presets"])["presets"] as? [[String: Any]]
        XCTAssertEqual(presets?.count, PresetCatalog.all.count)
        XCTAssertEqual(send("settings", ["action": "set", "output.folder": "movies"])["ok"] as? Bool, true)
        XCTAssertEqual(model.settings.outputFolder, .movies)
        XCTAssertEqual(model.queue.settings.outputFolder, .movies, "the queue names with the new settings")
        XCTAssertEqual(send("settings", ["action": "set", "output.folder": "nowhere"])["ok"] as? Bool, false)
        XCTAssertEqual(FFmpegSettings.load(from: dir.appendingPathComponent("preferences.json")).outputFolder, .movies)
    }

    func testPanelVerbs() {
        XCTAssertEqual(send("panel", ["id": "tools", "action": "show"])["visible"] as? Bool, true)
        XCTAssertEqual(send("panel", ["id": "tools", "action": "mode", "mode": "compact"])["mode"] as? String, "compact")
        XCTAssertTrue(model.isCompact)
        XCTAssertEqual(send("panel", ["id": "tools", "action": "hide"])["visible"] as? Bool, false)
        XCTAssertEqual(send("panel", ["id": "tools", "action": "show"])["mode"] as? String, "compact", "summon restores the mode")
        XCTAssertEqual(send("panel", ["id": "nope", "action": "show"])["ok"] as? Bool, false)
    }

    func testSnapshotAction() throws {
        panel.show(takeFocus: false)
        let path = dir.appendingPathComponent("snap.png").path
        XCTAssertEqual(send("action", ["name": "snapshot", "path": path])["ok"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
