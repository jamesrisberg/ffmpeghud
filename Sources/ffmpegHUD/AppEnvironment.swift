import Foundation

/// Isolation switches for tests and parallel instances:
///
/// - `FFMPEGHUD_HOME`: base directory (settings in `<home>/preferences.json`); default
///   `~/Library/Application Support/ffmpegHUD`. An isolated instance also keeps its panel
///   frames and recent presets apart from the real one's.
/// - `FFMPEGHUD_SOCKET`: socket name under MacHUD's sockets directory; default `ffmpeghud`.
/// - `FFMPEGHUD_NO_HOTKEYS`: set to skip registering the global hotkey.
enum AppEnvironment {
    static let environment = ProcessInfo.processInfo.environment

    static var isolatedHome: String? {
        environment["FFMPEGHUD_HOME"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var baseDirectory: URL {
        if let home = isolatedHome {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ffmpegHUD", isDirectory: true)
    }

    static var settingsURL: URL { baseDirectory.appendingPathComponent("preferences.json") }

    /// Panel frames and recent presets: the app's defaults, or a separate suite when
    /// `FFMPEGHUD_HOME` isolates this instance (so a test run never moves the real panel).
    /// Unit tests swap in a `MemoryStore` so they write no preferences at all.
    nonisolated(unsafe) static var store: KeyValueStore = isolatedHome == nil
        ? UserDefaults.standard
        : UserDefaults(suiteName: "xyz.machud.ffmpeghud.isolated") ?? UserDefaults.standard

    static func socketName(default name: String) -> String {
        environment["FFMPEGHUD_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? name
    }

    static var hotKeysEnabled: Bool { environment["FFMPEGHUD_NO_HOTKEYS"] == nil }
}

/// The little that is remembered between launches (panel frames, recent presets).
protocol KeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// In-memory `KeyValueStore`, for tests.
final class MemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
