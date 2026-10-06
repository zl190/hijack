import CoreGraphics
import Foundation
import os

// MARK: engine — carries out what the state machine decides, through the seams in Seams.swift.
// No live system call in this file. The app injects them (Sources/System.swift); the tests inject fakes.

public let capsuleGrace = 0.15  // after its voice window disappears, wait this long, then switch back
public let maxSwitchWait = 1.0  // give up waiting for the input source switch after this long

/// Timing marks for Instruments (Points of Interest): one interval per dictation, its phases, and key moments.
/// Free when nothing is recording. `scripts/sequence.sh` turns a recording into the sequence diagram.
public let signposter = OSSignposter(subsystem: "com.zl190.hijack", category: .pointsOfInterest)

/// Everything a session needs from the settings, read once per session. The app builds it from `Model`.
public struct Plan: Equatable {
    public var trigger: KeySpec
    public var providerID: String  // the voice tool, for its processes
    public var switchesInput: Bool  // an input method: switch to it and back. false: an app with its own hotkey
    public var voiceID: String
    public var voiceName: String
    public var forwardKey: KeySpec
    public var style: String  // how the voice tool wants its key: "hold" | "tap" | "doubleTap"
    public var toggle: Bool
    public var stopOnAnyKey: Bool
    public var holdDelay: Double
    public var restoreTimeout: Double
    public var fallbackDelay: Double

    // A public struct has no public memberwise init; this one keeps the same argument order.
    public init(
        trigger: KeySpec, providerID: String, switchesInput: Bool, voiceID: String, voiceName: String,
        forwardKey: KeySpec, style: String, toggle: Bool, stopOnAnyKey: Bool, holdDelay: Double,
        restoreTimeout: Double, fallbackDelay: Double
    ) {
        self.trigger = trigger; self.providerID = providerID; self.switchesInput = switchesInput
        self.voiceID = voiceID; self.voiceName = voiceName; self.forwardKey = forwardKey; self.style = style
        self.toggle = toggle; self.stopOnAnyKey = stopOnAnyKey; self.holdDelay = holdDelay
        self.restoreTimeout = restoreTimeout; self.fallbackDelay = fallbackDelay
    }
}

/// What one dictation did, for the single line it leaves in the log.
public struct DictationRecord {
    public var pressedAt: Date
    public var keySentMs: Int?  // shortcut down → talk key sent (nil: released before it was sent)
    public var echoMs: Int?  // shortcut down → our talk key's press came back through our own tap
    public var releasedAt: Date?
    public var heldMic: (tool: Bool?, device: Bool?)?  // last sample while the talk key was held
    public var heldWindow: WindowState?  // same sample
    public var sawWindow: Bool = false  // its voice window was on screen at some point after release
    public var windowGoneMs: Int?  // release → voice window gone (the text is in)
    public var postSeen: Bool?  // 0.3 s after the talk key went out, the system key state shows it down (nil: not sampled)
    public var switchFailed: Bool = false  // the input source never switched: the talk key was not sent (FM-05)
}

public final class Engine {
    public let makePlan: () -> Plan
    public let keys: KeyPoster
    public let sources: InputSources
    public let tap: TapControl
    public let probes: Probes
    public let clock: Scheduler
    public let sink: Sink

    public private(set) var plan: Plan
    public var previous: String?  // the input source to restore after this dictation
    public var generation: Int = 0
    public var physicalDown: Bool = false  // the shortcut as the keyboard has it (edges go to the machine)
    public var machine: SessionMachine = SessionMachine()  // what a press does: Sources/Core/SessionMachine.swift
    public var mode: SessionMode = SessionMode()  // fixed per press
    public var record: DictationRecord
    public var waited: TimeInterval = 0  // release → switch back, for the summary
    /// The voice tool's processes, looked up once per dictation.
    /// Listing running apps asks other processes. That is too slow to repeat every 50 ms.
    public var voicePIDs: [pid_t] = []
    public var tapInstalled: Bool = false
    public var span: (id: OSSignpostID, dictation: OSSignpostIntervalState, phase: (name: StaticString, state: OSSignpostIntervalState))?

    public var swallowUp: Int?  // key that stopped a toggle session: also eat its key-up
    public var quitting: Bool = false  // inside stopForQuit(): endVoice() must post the stop tap synchronously (M1)
    public var paused: Bool = false  // the settings window is recording a key: let every key through
    public var recordingToken: Int = 0  // review-5 #8: invalidates a stale pauseForKeyRecording() timeout
    public var forwardKeyEdgeSeen: Bool = false  // an edge of the talk key came through the tap since start (S2)
    public var waitingReported: Bool = false
    public var micOffSince: Date?  // when the held-mic sample first read "off"; reset each dictation (FM-09)

    public init(plan: @escaping () -> Plan, deps: Deps) {
        makePlan = plan
        keys = deps.keys; sources = deps.sources; tap = deps.tap; probes = deps.probes; clock = deps.clock; sink = deps.sink
        self.plan = plan()
        record = DictationRecord(pressedAt: deps.clock.now)
    }

    public func log(_ line: String) { sink.log(line) }
    public func trace(_ msg: @autoclosure @escaping () -> String) { sink.trace(msg()) }  // stays lazy: msg() is inside the new autoclosure

    /// Re-read the settings, between sessions only, so a change mid-session can't strand a held key.
    public func refresh() {
        guard machine.state == .idle, !physicalDown else { return }
        plan = makePlan()
    }

    // Live progress for the settings window's "Try it" area.
    public func report(_ phase: String, _ detail: String = "") { sink.report(phase, detail) }

    // Turn the session into what the voice method expects: hold its key, or tap / double-tap it.
    public func tapKey(after delay: Double = 0) {
        let key = plan.forwardKey
        clock.after(delay) { [self] in
            post(key, down: true)
            clock.after(0.03) { [self] in post(key, down: false) }
        }
    }
    public func startVoice() {
        switch plan.style {
        case "tap": tapKey()
        case "doubleTap": tapKey(); tapKey(after: 0.12)
        default: post(plan.forwardKey, down: true)
        }
    }
    public func endVoice() {
        if plan.style == "hold" {
            post(plan.forwardKey, down: false)
        } else if quitting {
            synchronousTapForQuit()
        }  // M1: a scheduled tapKey() would never run before exit()
        else {
            tapKey()
        }  // "press any key to finish"
    }

    /// The stop tap, inline (M1, docs/review-4/hardening-review.md): used only from stopForQuit(), where
    /// terminate() calls exit() right after applicationWillTerminate returns, so a post scheduled through
    /// clock.after (DispatchQueue.main.asyncAfter on the live Scheduler) would never run. Timing matches
    /// tapKey()'s own (30ms down-to-up; 120ms from the first tap's down to the second's, for doubleTap).
    public func synchronousTapForQuit() {
        let key = plan.forwardKey
        post(key, down: true); usleep(30_000); post(key, down: false)
        if plan.style == "doubleTap" {
            usleep(90_000)
            post(key, down: true); usleep(30_000); post(key, down: false)
        }
    }

    /// A source rebuilt before the first post after a gap longer than this (W7).
    public static let idleRebuildAfter: TimeInterval = 600
    public var lastPostAt: Date?

    public func post(_ key: KeySpec, down: Bool) {
        let now = clock.now
        if let last = lastPostAt, now.timeIntervalSince(last) > Self.idleRebuildAfter {
            keys.rebuild(reason: "idle \(Int(now.timeIntervalSince(last) / 60))m")
        }
        lastPostAt = now
        if !keys.post(key, down: down) { log("couldn't create the \(key.name) \(down ? "press" : "release") event") }
    }

    public func ms(since d: Date) -> Int { Int(clock.now.timeIntervalSince(d) * 1000) }

    // Phases of one dictation: "starting" (press → talk key sent), "listening" (→ release), "waiting for text" (→ switch back).
    public func beginDictation() {
        let id = signposter.makeSignpostID()
        span = (id, signposter.beginInterval("dictation", id: id), ("starting", signposter.beginInterval("starting", id: id)))
    }
    public func enterPhase(_ name: StaticString) {
        guard let s = span else { return }
        signposter.endInterval(s.phase.name, s.phase.state)
        span?.phase = (name, signposter.beginInterval(name, id: s.id))
    }
    public func endDictation() {
        guard let s = span else { return }
        signposter.endInterval(s.phase.name, s.phase.state)
        signposter.endInterval("dictation", s.dictation)
        span = nil
    }
    public func mark(_ name: StaticString) { if let s = span { signposter.emitEvent(name, id: s.id) } }

    public func sendKey() {
        voicePIDs = probes.processIDs(ofProvider: plan.providerID)
        record.keySentMs = ms(since: record.pressedAt)
        enterPhase("listening"); mark("talk key sent")
        startVoice()
        sampleWhileHeld(gen: generation, after: 0.3)
        report("listening", plan.voiceName)
        trace("forward \(self.plan.forwardKey.name) start (\(self.plan.style)) after \(self.record.keySentMs ?? 0)ms")
    }

    /// Select and confirm: re-read the current source a moment later and retry once if it didn't stick.
    /// `confirmed`, when given, reports whether `id` is current after that check (FM-16: a caller must not
    /// tell the user the switch happened before this runs).
    public func switchTo(_ id: String, _ label: String, confirmed: ((Bool) -> Void)? = nil) {
        let ok = sources.select(id)
        clock.after(0.1) { [self] in
            if sources.current() == id {
                trace("\(label) \(id) ok=\(ok)"); confirmed?(true)
            } else {
                let retryOK = sources.select(id)
                log("\(label) \(id) didn't stick, retry ok=\(retryOK)")
                confirmed?(sources.current() == id)
            }
        }
    }

    /// Hand an event to the state machine and carry out what it returns. Returns whether the key event passes.
    @discardableResult
    public func run(_ event: SessionEvent, keyCode: Int? = nil) -> Bool {
        let p = plan
        if event == .press {
            // The shortcut is the tool's own key and the tool is already in front: it gets the real key.
            let sameKey = p.trigger == p.forwardKey && !p.toggle && p.style == "hold"
            mode = SessionMode(
                toggle: p.toggle, switchesInput: p.switchesInput,
                passthrough: sameKey && (!p.switchesInput || sources.current() == p.voiceID))
        }
        let before = machine.state
        let effects = machine.handle(event, mode)
        let after = machine.state
        trace("\(event.rawValue): \(before.rawValue) → \(after.rawValue) \(effects.map { "\($0)" })")
        if (before == .starting || before == .listening) && (machine.state == .waitingForText || machine.state == .idle) {
            record.releasedAt = clock.now; enterPhase("waiting for text")
        }
        // Settings changed mid-dictation apply now. refresh() rebuilds the Plan, which can read a voice
        // provider's own settings file (review-5 #3): off the tap, not inline, so a key event never does
        // file I/O. refresh()'s own guard (idle, !physicalDown) still covers a press that comes first.
        defer { if machine.state == .idle { clock.after(0) { [self] in refresh() } } }
        var pass = false
        for effect in effects {
            switch effect {
            case .passKey: pass = true
            case .swallowKey: pass = false
            case .swallowKeyAndItsRelease: pass = false; swallowUp = keyCode
            case .finishPrevious: summary(end: "interrupted by the next press")  // the retry after a failure must not erase it
            case .begin:
                generation += 1; record = DictationRecord(pressedAt: clock.now); voicePIDs = []; micOffSince = nil; beginDictation()
            case .switchToVoice:
                let cur = sources.current()
                if let cur, cur != p.voiceID { previous = cur }
                // After the tap returns: nothing slow inside the tap, every tap after ours would wait for it.
                if cur != p.voiceID { clock.after(0) { [self] in switchTo(p.voiceID, "switch to") } }
                report("switching", p.voiceName)
            case .scheduleTalkKey: scheduleTalkKey()
            case .sendTalkKey: sendKey()
            case .releaseTalkKey: endVoice()
            case .waitForText: report("finishing", p.voiceName); waitForText()
            case .finish: finish()
            }
        }
        return pass
    }

    /// Send the talk key once the input source is ready and the hold delay is over (an app: after the delay).
    /// When the source is still wrong after `maxSwitchWait`, the dictation ends without the talk key (FM-05).
    public func scheduleTalkKey() {
        let p = plan, gen = generation, start = clock.now
        func whenReady() {
            guard machine.state == .starting, gen == generation else { trace("released before forward"); return }
            let ready = !p.switchesInput || sources.current() == p.voiceID
            let waited = clock.now.timeIntervalSince(start)
            if ready && waited >= p.holdDelay {
                run(.keySent)
            } else if !ready && waited >= maxSwitchWait {  // a holdDelay above maxSwitchWait is not a failed switch (review-4 N1)
                record.switchFailed = true
                log("input source never switched to \(p.voiceID) after \(Int(waited * 1000))ms, talk key not sent")
                run(.switchFailed)
            } else {
                clock.after(0.02) { whenReady() }
            }
        }
        clock.after(0.02) { whenReady() }
    }

    /// Watch the voice window: when it goes (plus a short grace), or the wait runs out, the text is in.
    public func waitForText() {
        let p = plan, gen = generation, released = record.releasedAt ?? clock.now
        var windowGone: Date?
        func poll() {
            guard gen == generation, machine.state == .waitingForText else { return }
            let waited = clock.now.timeIntervalSince(released)
            if voicePIDs.isEmpty { voicePIDs = probes.processIDs(ofProvider: p.providerID) }  // released before the key was sent
            let visible = probes.windows(of: voicePIDs).busy
            if visible == true { record.sawWindow = true }
            if record.sawWindow && windowGone == nil && visible == false {
                windowGone = clock.now; record.windowGoneMs = ms(since: released); mark("window gone")
            }
            let graceDone = windowGone.map { clock.now.timeIntervalSince($0) >= capsuleGrace } ?? false
            guard graceDone || waited >= (record.sawWindow ? p.restoreTimeout : p.fallbackDelay) else {
                clock.after(0.05) { poll() }; return
            }
            self.waited = waited
            run(.textDone)
        }
        clock.after(0.05) { poll() }
    }

    /// The dictation is over: write its line; an input method also switches back to where you were.
    public func finish() {
        let p = plan
        let prev = previous; previous = nil  // consumed here, not at .begin: a chained dictation keeps it (FM-17)
        if record.switchFailed {
            summary(end: "input source never switched"); report("done", "")
            // The switch can still land after we gave up. Then the user would stay in the voice IME (review-4 S1).
            if let prev {
                clock.after(0.5) { [self] in
                    guard sources.current() == p.voiceID else { return }
                    log("input source switched late: restore after failed switch to \(prev)")
                    switchTo(prev, "restore after failed switch")
                }
            }
            return
        }
        guard p.switchesInput else { summary(end: "no switch back needed"); report("done", p.voiceName); return }
        guard let prev else {
            summary(end: "started inside \(p.voiceName), nothing to switch back to"); report("done", p.voiceName); return
        }
        guard sources.current() == p.voiceID else {
            summary(end: "input source already changed, not switched back"); report("done", ""); return
        }
        summary(end: "back after \(String(format: "%.2f", waited))s")
        let name = sink.sourceName(prev), voiceName = p.voiceName, waitedText = waited
        // "Try it" must not say "back to X" until the switch is confirmed (FM-16): report only once we know.
        switchTo(prev, "restore") { [self] confirmed in
            report(
                "done",
                confirmed
                    ? localize(
                        "等上屏 \(String(format: "%.1f", waitedText)) 秒，已切回 \(name)",
                        "waited \(String(format: "%.1f", waitedText))s for the text, back to \(name)")
                    : localize("没切回，输入源仍是\(voiceName)", "Didn't switch back; the input source is still \(voiceName)"))
        }
    }

    /// While the talk key is held: is the voice tool listening, and is its window up? Sampled every half
    /// second off the main thread (CoreAudio and the window list are slow for a key tap); release keeps the last.
    public func sampleWhileHeld(gen: Int, after delay: Double) {
        clock.after(delay) { [self] in
            guard machine.state == .listening, gen == generation else { return }
            // W7: did the system see our talk key go down? Only a held key can be read back: a tapped
            // key is already up by now. A cheap state read, so it stays on the main thread.
            if record.postSeen == nil, plan.style == "hold" {
                let key = plan.forwardKey
                record.postSeen = key.modifierOnly ? key.named?.flag.map { tap.modifierIsDown($0) } ?? false : tap.keyIsDown(key.code)
            }
            let pids = voicePIDs, watched = plan.switchesInput, probes = probes
            clock.offMain({ () -> ((Bool?, Bool?), WindowState) in
                let mic = (probes.micInUse(by: pids), probes.micInUse(by: nil))
                let window: WindowState = watched ? probes.windows(of: pids) : .unknown("an app: its window isn't watched")
                return (mic, window)
            }) { [self] mic, window in
                guard gen == generation else { return }
                record.heldMic = mic; record.heldWindow = window
                // A sample started before the release can complete after it (review-4 S1): the dictation
                // is already over, so its reading is stale and must not overwrite the UI's post-release text.
                if machine.state == .listening {
                    // FM-09: the tool's own mic reads off. Say so once it's held for 1s (a blip isn't a fault);
                    // an "unknown" (nil) reading never overrides "正在听…" (FM-12: the probe itself can be wrong).
                    if mic.0 == false {
                        if let since = micOffSince {
                            if clock.now.timeIntervalSince(since) >= 1.0 {
                                report("notListening", plan.voiceName)
                            }
                        } else {
                            micOffSince = clock.now
                        }
                    } else if micOffSince != nil {
                        micOffSince = nil; report("listening", plan.voiceName)  // recovered (or now unknown): back to normal
                    }
                }
                sampleWhileHeld(gen: gen, after: 0.5)
            }
        }
    }

    // The one line per dictation that goes to the file. When it didn't work, the checks tell which step failed:
    // the key never went out (echo), the voice tool didn't start listening (mic), or we missed its window.
    public func summary(end: String) {
        let p = plan, r = record
        let held = (r.releasedAt ?? clock.now).timeIntervalSince(r.pressedAt)
        // review-5 #17: the tool and the key are logged by their stable id, not `.name`/`.voiceName` (both
        // run through `localize`), so a language change does not split one tool into two in `hijack stats`.
        var line = "dictation \(p.providerID) (\(p.toggle ? "toggle" : "hold")): held \(String(format: "%.2f", held))s"
        if let sent = r.keySentMs {
            func onOff(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "?" }
            line += ", \(p.forwardKey.logID) sent after \(sent)ms"
            if p.switchesInput {
                line += r.windowGoneMs.map { ", window closed \($0)ms after release" } ?? ", window never closed after release"
            }
            line += ", \(end)"
            line +=
                " | echo \(r.echoMs.map { "after \($0)ms" } ?? "missing"), post: \(r.postSeen.map { $0 ? "seen" : "not seen" } ?? "?"), mic tool \(onOff(r.heldMic?.tool)) device \(onOff(r.heldMic?.device))"
            if p.switchesInput { line += ", window while held: \(r.heldWindow?.text ?? "?")" }
        } else if r.switchFailed {
            line += ", \(end)"
        } else {
            line += ", released before \(p.forwardKey.logID) was sent"
        }
        if tapInstalled, !tap.isEnabled { line += ", key tap disabled" }
        if tap.secureInputOn { line += ", secure input on" }
        log(line + " | \(probes.frontApp())")
        endDictation()
    }

    /// The tap was off for a while, so key events may have been missed: line our idea of the trigger up with
    /// the keyboard. A missed release would leave the talk key held and the next press swallowed.
    public func reconcile() {
        let downNow = tap.keyIsDown(plan.trigger.code)
        guard downNow != physicalDown else { return }
        log("trigger is \(downNow ? "down" : "up") but we had it \(physicalDown ? "down" : "up"): catching up")
        physicalDown = downNow
        if !downNow && machine.isActive && !plan.toggle { run(.release) }
    }

    public enum Wake { case systemWake, screenUnlock }
    public var sleptAt: Date?  // the last willSleep notification
    public var lockedAt: Date?  // the last screenIsLocked notification
    public func systemWillSleep() { sleptAt = clock.now }
    public func screenLocked() { lockedAt = clock.now }

    /// After sleep or unlock the voice tool and the input sources are in an unknown state (FM-25).
    /// A session that was running across it stops now, in hold and in toggle mode. A session that started
    /// after the sleep or the lock is the user's: the notification came late (review-4 S3). Then the trigger is re-read.
    public func reconcileAfterWake(_ wake: Wake) {
        let reason = wake == .systemWake ? "system wake" : "screen unlocked"
        if wake == .systemWake { keys.rebuild(reason: "system wake") }
        let since = wake == .systemWake ? sleptAt : lockedAt
        if machine.isActive, since.map({ record.pressedAt < $0 }) ?? true {
            log("session was active across \(reason): stopping it")
            run(plan.toggle ? .press : .release)
        }
        physicalDown = tap.keyIsDown(plan.trigger.code)
    }

    /// The forward key as the system has it. A crash while the talk key was held leaves it down (FM-10).
    /// Runs 1 s after the tap starts. The system state cannot tell a stuck key from a key the user holds:
    /// an edge of the key through the tap in that second means a hand is on it, so nothing is posted.
    /// Limit: a user who holds the talk key for more than 1 s across a launch gets one release posted.
    public func clearStuckModifier() {
        guard !physicalDown, !forwardKeyEdgeSeen else { return }
        let key = plan.forwardKey
        let down = key.modifierOnly ? key.named?.flag.map { tap.modifierIsDown($0) } ?? false : tap.keyIsDown(key.code)
        guard down else { return }
        post(key, down: false)
        log("cleared a stuck \(key.name)")
    }

    /// Review-5 #8: how long Settings' key recorder may hold the engine paused before the pause clears on
    /// its own. Switching apps (or anything else that strands the recorder open) used to kill dictation
    /// for good, with no fault line to say why.
    public static let recordingPauseTimeout = 30.0

    /// Review-6 S1: the timeout only cleared `paused`; Settings' own recording state (the "Press a Key…"
    /// button, the local NSEvent monitor) was untouched, so a forgotten recording still looked live after
    /// 30s even though the engine had already resumed. Settings sets this to `stopRecording` so the
    /// timeout can end the recording on both sides at once.
    public var onKeyRecordingTimeout: (() -> Void)?

    /// Settings' key recorder calls this to pause the engine (`paused = true`: every key passes through,
    /// nothing starts a dictation) while it waits for the next key press. `recordingToken` is bumped and
    /// captured so a stale timeout from an earlier, already-finished recording can never clear a later
    /// one's pause (the same generation-guard shape as `scheduleTalkKey`/`waitForText`), or call
    /// `onKeyRecordingTimeout` for a recording that already ended.
    public func pauseForKeyRecording() {
        paused = true
        recordingToken += 1
        let token = recordingToken
        clock.after(Engine.recordingPauseTimeout) { [self] in
            guard token == recordingToken else { return }
            paused = false
            log("key recording timed out after \(Int(Engine.recordingPauseTimeout))s; dictation resumed")
            onKeyRecordingTimeout?()
        }
    }

    /// Settings calls this when the recording ends normally (a key was recorded, or Esc cancelled it).
    public func resumeFromKeyRecording() {
        paused = false
        recordingToken += 1  // invalidate any pending timeout from this recording
    }

    /// Stop a session the menu finds still active with the physical key already up (FM-01, FM-04, FM-25):
    /// the same stop path `reconcileAfterWake` uses after sleep or unlock.
    public func stopStuckSession() {
        guard machine.isActive else { return }
        run(plan.toggle ? .press : .release)
        physicalDown = tap.keyIsDown(plan.trigger.code)  // resync, as reconcileAfterWake does (review-4 M3):
        // without this the next real press reads as a repeat of a press that never happened, and is swallowed.
    }

    /// The app is quitting (AppDelegate.applicationWillTerminate, or SIGTERM routed through it): a held
    /// talk key must not outlive the process (FM-10, at the source). No restore-input-source wait — the
    /// process exits right after this call, so `.quit` goes straight to idle instead of `waitingForText`.
    public func stopForQuit() {
        // S2: one log line either way, so a field log can show whether a quit released a key.
        guard machine.isActive else { log("quit: nothing held"); return }
        let releasing = machine.state == .listening  // the only state where a talk key was actually sent
        let key = plan.forwardKey.logID
        quitting = true
        run(.quit)
        quitting = false
        log(releasing ? "quit: released \(key)" : "quit: nothing held")
    }

    /// Re-enable the tap and check that it took (FM-02). One retry on the next run-loop turn; state.json tells the menu.
    public func reenableTap(_ why: String) {
        guard tap.trusted else {  // Accessibility was revoked while running (FM-24): re-enabling can't work
            log("event tap disabled (\(why)): Accessibility permission is gone")
            clock.after(0) { [self] in sink.state(trusted: false, tapActive: false) }  // off the tap callback (review-4 M2)
            return
        }
        tap.enable()
        signposter.emitEvent("tap disabled")
        if tap.isEnabled {
            log("event tap was disabled by the system (\(why)), re-enabled")
        } else {
            log("event tap was disabled by the system (\(why)), re-enable failed, retrying")
            clock.after(0) { [self] in  // off the tap callback: state.json is file I/O (review-4 S5)
                sink.state(trusted: true, tapActive: false)
                tap.enable()
                let ok = tap.isEnabled
                sink.state(trusted: true, tapActive: ok)
                log(ok ? "event tap re-enabled on retry" : "event tap still disabled after retry")
            }
        }
        clock.after(0) { [self] in reconcile() }
    }

    /// One key event from the tap. Returns true when the event passes to the system, false when Engine swallows it.
    public func handle(_ input: KeyInput) -> Bool {
        if input.kind == .tapDisabledByTimeout || input.kind == .tapDisabledByUserInput {
            reenableTap(input.kind == .tapDisabledByTimeout ? "timeout" : "user input")
            return true
        }
        let p = plan
        let code = input.code
        if code == p.forwardKey.code, !input.ours { forwardKeyEdgeSeen = true }
        if input.ours {
            // Our own talk key came back through our tap: it was posted. Count only its press.
            if code == p.forwardKey.code, record.echoMs == nil, isPress(input, p.forwardKey) {
                record.echoMs = ms(since: record.pressedAt); mark("echo")
            }
            return true
        }
        guard !paused else { return true }
        if input.kind == .keyUp, code == swallowUp { swallowUp = nil; return false }
        // Toggle session running: any other key stops it, and is not typed (Return must not send a message).
        if machine.isActive && p.toggle && p.stopOnAnyKey && input.kind == .keyDown && code != p.trigger.code {
            return run(.otherKey, keyCode: code)
        }
        let trigger = p.trigger
        guard code == trigger.code else { return true }
        let down: Bool
        if trigger.modifierOnly {
            guard input.kind == .flagsChanged, let n = trigger.named, let flag = n.flag else { return true }
            down = n.device == 0 ? input.flags.contains(flag) : input.flags.rawValue & n.device != 0
        } else {
            guard input.kind == .keyDown || input.kind == .keyUp else { return true }
            let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
            if input.kind == .keyDown && !physicalDown && input.flags.intersection(relevant) != trigger.flags.intersection(relevant) {
                return true  // same key, different modifiers: not ours
            }
            down = input.kind == .keyDown
        }
        // A release whose press we never saw (the tap was off): not ours to swallow, or the key stays down for everyone.
        if !down && !physicalDown { return true }
        // A repeat while held: the tool's own key keeps its repeats, ours are swallowed.
        if down == physicalDown { return machine.state == .passthrough }
        physicalDown = down
        return run(down ? .press : .release)
    }

    public func isPress(_ input: KeyInput, _ key: KeySpec) -> Bool {
        if input.kind == .keyDown { return true }
        guard input.kind == .flagsChanged, let flag = key.named?.flag else { return false }
        return input.flags.contains(flag)
    }

    public func start() {
        guard tap.trusted else {
            if !waitingReported { sink.state(trusted: false, tapActive: false); waitingReported = true }
            clock.after(1) { self.start() }  // wait for the grant
            return
        }
        plan = makePlan()
        guard tap.install({ [unowned self] input in self.handle(input) }) else {
            sink.state(trusted: true, tapActive: false); clock.after(1) { self.start() }; return
        }
        tapInstalled = true
        tap.enable()
        let on = tap.isEnabled
        sink.state(trusted: true, tapActive: on)
        if !on { log("event tap installed but not enabled") }
        forwardKeyEdgeSeen = false
        clock.after(1) { [self] in clearStuckModifier() }
        log("started: trigger \(plan.trigger.name), forward \(plan.forwardKey.name), voice \(plan.voiceID)")
    }
}
