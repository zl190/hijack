import CoreGraphics
import Foundation

// MARK: seams — the system services that Engine uses, as protocols.
// The app installs the live implementations (Sources/System.swift). The tests install fakes and inject faults.
// Each protocol is one FMEA seam (docs/fmea.md, "What has to be injectable").

/// Localized text. The app sets this to `L` at launch. Core and the tests default to English.
public var localize: (String, String) -> String = { _, en in en }

/// One key event from the tap, reduced to what Engine reads.
public struct KeyInput: Equatable {
    public enum Kind: Equatable { case keyDown, keyUp, flagsChanged, tapDisabledByTimeout, tapDisabledByUserInput }
    public var kind: Kind
    public var code: Int = 0
    public var flags: CGEventFlags = []
    public var ours: Bool = false  // posted by Engine itself (the event carries the marker)

    public init(kind: Kind, code: Int = 0, flags: CGEventFlags = [], ours: Bool = false) {
        self.kind = kind; self.code = code; self.flags = flags; self.ours = ours
    }
}

/// Posts key events to the system. Returns false when the system refuses to create the event (FM-08).
public protocol KeyPoster {
    @discardableResult func post(_ key: KeySpec, down: Bool) -> Bool
    /// Replace the event source the posts go through (W7): a source held across system sleep can stop reaching the HID stream.
    func rebuild(reason: String)
}

/// The keyboard input sources (TIS).
public protocol InputSources {
    func current() -> String?
    func select(_ id: String) -> Bool
}

/// The event tap and the system key state.
public protocol TapControl: AnyObject {
    var trusted: Bool { get }  // Accessibility granted
    func install(_ onEvent: @escaping (KeyInput) -> Bool) -> Bool  // create the tap; false when the system refuses
    var isEnabled: Bool { get }
    func enable()
    func keyIsDown(_ code: Int) -> Bool  // the key as the keyboard has it
    func modifierIsDown(_ flag: CGEventFlags) -> Bool  // the modifier as the system has it
    /// W7: is the talk key down right now, in the HID system state and in the combined session state?
    func postedKeyVisible(_ key: KeySpec) -> (hid: Bool, session: Bool)
    var secureInputOn: Bool { get }
}

/// What we can see of a voice tool's windows. `.unknown` says why we can't tell.
public enum WindowState: Equatable {
    case visible(Int)
    case none(String)
    case unknown(String)
    public var busy: Bool? {
        switch self {
        case .visible: return true;
        case .none: return false;
        case .unknown: return nil
        }
    }
    public var text: String {
        switch self {
        case .visible(let n): return "\(n) window\(n == 1 ? "" : "s")";
        case .none(let why), .unknown(let why): return why
        }
    }
}

/// W9: how the system treats this process right now. `napped`: App Nap is engaged (the task suppression
/// policy's `active` word). `role`: the Mach task role (1 foreground, 2 background, 7 default, ...).
public struct ProcessState: Equatable {
    public var napped: Bool
    public var role: Int
    public init(napped: Bool, role: Int) { self.napped = napped; self.role = role }
}

/// Probes of the voice tool: its processes, its windows, the microphone, the app in front.
public protocol Probes {
    func processIDs(ofProvider id: String) -> [pid_t]
    func windows(of pids: [pid_t]) -> WindowState
    func micInUse(by pids: [pid_t]?) -> Bool?  // nil: by anyone on the default input device
    func frontApp() -> String
    /// W9: this process's App Nap state and task role; nil when the system call fails.
    func processState() -> ProcessState?
}

/// Time and deferred work. The live one is the main queue. The fake one advances by hand.
public protocol Scheduler {
    var now: Date { get }
    func after(_ seconds: Double, _ work: @escaping () -> Void)
    /// Run `work` off the main thread, then `done` with its result on the main thread.
    func offMain<T>(_ work: @escaping () -> T, then done: @escaping (T) -> Void)
}

/// Where Engine writes: the log file, the trace, the settings window, state.json.
public protocol Sink {
    func log(_ line: String)
    func trace(_ msg: @autoclosure @escaping () -> String)  // built only when someone streams the debug log
    func report(_ phase: String, _ detail: String)
    func state(trusted: Bool, tapActive: Bool)
    func sourceName(_ id: String) -> String
}

/// The process around Engine (W8, docs/adr/0022-relaunch-on-a-failed-post.md): restart it, and remember when it last did.
/// Engine owns the signature and the rate limit; the app side owns the Process call and UserDefaults.
public protocol Supervisor: AnyObject {
    /// Start a fresh copy of the app and quit this one. `reason` goes to the log by the caller; the live one
    /// also marks the exit as a self-relaunch so the next `started:` line can say so.
    func relaunch(reason: String)
    /// When the app last relaunched itself. Persisted, so a process that is broken from birth cannot loop.
    var lastRelaunchAt: Date? { get set }
    /// True once when the previous exit was a self-relaunch (and clears the mark). Read at startup.
    func takeSelfRelaunchMark() -> Bool
}

/// A watch on a set of folders, notifying once when something inside one of them changes. The live
/// implementation (Sources/Core/Watch.swift) wraps FSEvents; the tests drive a fake by hand, with no
/// real latency. One seam, not part of `Deps`: `SettingsWatch` is used from Menu.swift, outside Engine.
public protocol FolderEvents: AnyObject {
    /// Start watching `roots` (already filtered to the ones that exist). Returns whether it is now
    /// watching: false when `roots` is empty, or the live stream could not be created.
    @discardableResult func start(roots: [String], latency: Double, onChange: @escaping () -> Void) -> Bool
}

public struct Deps {
    public var keys: KeyPoster
    public var sources: InputSources
    public var tap: TapControl
    public var probes: Probes
    public var clock: Scheduler
    public var sink: Sink
    public var supervisor: Supervisor

    public init(
        keys: KeyPoster, sources: InputSources, tap: TapControl, probes: Probes, clock: Scheduler, sink: Sink, supervisor: Supervisor
    ) {
        self.keys = keys; self.sources = sources; self.tap = tap; self.probes = probes; self.clock = clock; self.sink = sink
        self.supervisor = supervisor
    }
}
