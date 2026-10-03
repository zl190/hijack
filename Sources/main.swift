// Hijack — hold a key to dictate with a voice input method (default WeType) from any input source; the previous input source
// comes back after release. Settings live in ~/.config/hijack/config.json; the menu bar menu edits the common
// ones and the settings window (⌘, or open the app again) all of them.
// Build: ./build.sh (all files in Sources/)
import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

localize = L   // Core (Keys, Engine) speaks the configured language

// `hijack <command>` runs the CLI and exits; anything else starts the app.
if let code = runCLI(Array(CommandLine.arguments.dropFirst())) { exit(code) }

// A second launch (double-click, Spotlight, the relauncher after an update) must not install a second
// event tap. Checked after the CLI dispatch above, so `hijack status` still works while the app runs.
let myPID = ProcessInfo.processInfo.processIdentifier
if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.zl190.hijack")
    .first(where: { $0.processIdentifier != myPID }) {
    log("another Hijack is running (pid \(other.processIdentifier)), exiting")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// SIGTERM (launchd stop, `kill`, a relaunch during an update) must still run applicationWillTerminate,
// so a held talk key gets released (FM-10). SIG_IGN first: DispatchSource only sees the signal once the
// default disposition is ignored (dispatch/source.h).
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { NSApp.terminate(nil) }
sigtermSource.resume()

app.run()
