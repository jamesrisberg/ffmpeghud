import Foundation
import HUDKit
import XCTest
@testable import ffmpegHUD
import ffmpegHUDKit

/// The shipped machud.json, settings.json and Info.plist are what MacHUD reads without
/// launching ffmpegHUD; keep them valid and in step with the code.
final class ManifestTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ffmpegHUD/Resources")
    }

    private func manifest() throws -> HUDManifest {
        try HUDManifest.decode(Data(contentsOf: resources.appendingPathComponent(HUDManifest.fileName)))
    }

    func testManifestDecodes() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.id, "xyz.machud.ffmpeghud")
        XCTAssertEqual(manifest.name, "ffmpegHUD")
        XCTAssertEqual(manifest.socket, "ffmpeghud", "socket name = CLI name = repo name")
        let panel = try XCTUnwrap(manifest.panel(id: "tools"))
        XCTAssertEqual(panel.kind, .hover, "MacHUD drops the panel down on hover and hides it on leave")
        XCTAssertEqual(panel.capabilities, ["acceptsFileDrop"])
        XCTAssertEqual(panel.order, 3, "MacHUD's dock: Scratch 1, Stash 2, then ffmpegHUD")
        XCTAssertEqual(panel.defaultSize, HUDSize(width: 640, height: 500))
        XCTAssertEqual(panel.compactSize, HUDSize(width: 44, height: 44))
        for verb in ["show", "hide", "toggle", "drop", "run", "jobs"] {
            XCTAssertTrue(panel.verbs.contains(verb), verb)
        }
        let schema = try XCTUnwrap(panel.settingsSchema)
        let data = try Data(contentsOf: resources.appendingPathComponent(schema))
        XCTAssertNoThrow(try HUDSettingsSchema.decode(data))
        let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = (settings?["settings"] as? [[String: Any]])?.compactMap { $0["key"] as? String }
        XCTAssertEqual(Set(keys ?? []), ["output.folder", "output.customFolder", "naming.suffix", "keepOriginal", "jobs.concurrent"])
        XCTAssertEqual(Set(keys ?? []), Set(FFmpegSettings().json.keys), "the schema describes every setting the Kit stores")
    }

    @MainActor
    func testBuiltinManifestMirrorsTheFile() throws {
        XCTAssertEqual(ControlHost.builtinManifest, try manifest())
    }

    func testInfoPlist() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "xyz.machud.ffmpeghud")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "ffmpegHUD")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertNotNil(plist["NSHumanReadableCopyright"])
    }
}
