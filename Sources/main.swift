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
//
// An exclusive flock on a lock file (S4), not a process list: NSRunningApplication is a point-in-time
// snapshot with no exclusivity — two launches close together can each see zero others and both proceed,
// or each see the other mid-launch and both exit. The kernel releases the lock when a process dies, even
// to SIGKILL, so `make install` (pkill, then open) and the menu's Reopen action cannot race an instance
// that is still exiting: the new process just finds the lock held and exits cleanly instead.
let lockDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Hijack")
try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
let lockPath = lockDir.appendingPathComponent("instance.lock").path
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 {
    log("couldn't open \(lockPath) for the instance lock (errno \(errno)); continuing without the guard")
} else if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    let holder = (try? String(contentsOfFile: lockPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    log("another Hijack holds the instance lock (pid \(holder ?? "?")), exiting")
    exit(0)
} else {
    // Held: record our pid, for the next instance's log line if it loses the race. ftruncate first, so a
    // shorter new pid does not leave stale digits from whatever held the lock before us.
    ftruncate(lockFD, 0)
    let pid = Data("\(ProcessInfo.processInfo.processIdentifier)".utf8)
    pid.withUnsafeBytes { _ = write(lockFD, $0.baseAddress, $0.count) }
    // lockFD is deliberately never closed: the lock, and the fd holding it, live for the process lifetime.
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// SIGTERM (launchd stop, `kill`, a relaunch during an update), SIGINT (Ctrl-C on a binary run from a
// terminal) and SIGHUP must all still run applicationWillTerminate, so a held talk key gets released
// (FM-10, S2). SIG_IGN first, for each: DispatchSource only sees the signal once the default disposition
// is ignored (dispatch/source.h). Kept in a global array: each source needs a strong reference for the
// process lifetime, same as the single sigtermSource before it.
let quitSignalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}

app.run()
