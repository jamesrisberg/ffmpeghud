import AppKit

// Menu bar app: no Dock icon. Set the policy before the app finishes launching so the
// icon never bounces.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
