import SwiftUI
import AppKit

/// Anwendungsdelegate für Verhalten, das SwiftUI allein nicht abdeckt.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Macht die App auch dann zu einer normalen Vordergrund-App, wenn sie ohne `.app`-Bundle gestartet wird.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nötig, wenn die App direkt aus Xcode bzw. per `swift run` (ohne .app-Bundle) startet.
        NSApp.setActivationPolicy(.regular)
        // Ohne .app-Bundle (kein `CFBundleIconFile`) das Icon aus dem Logo rendern, damit Dock und
        // App-Wechsler nicht das Standard-Icon zeigen. Im Bundle gilt die mitgelieferte AppIcon.icns.
        MainActor.assumeIsolated {
            if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil {
                NSApp.applicationIconImage = AppIcon.image()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Beendet die App mit dem letzten Fenster (dabei wird ein laufendes CAT-Senden abgeschaltet).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Einstiegspunkt der App „Mike Foxtrott“ (FT-891 Control).
///
/// Die beiden Modelle – ``Radio`` (Gerät) und ``Logbook`` (Logbuch) – leben so lange wie die App
/// und werden als Umgebungsobjekte an alle Ansichten weitergereicht.
@main
struct FT891ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var radio: Radio
    @State private var logbook = Logbook()
    @State private var sweep: SweepController

    init() {
        let r = Radio()
        _radio = State(initialValue: r)
        _sweep = State(initialValue: SweepController(radio: r))
    }

    var body: some Scene {
        WindowGroup("Mike Foxtrott") {
            ContentView()
                .environment(radio)
                .environment(logbook)
                .environment(sweep)
        }
        .windowResizability(.contentMinSize)
    }
}
