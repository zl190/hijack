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
    /// W11 (docs/adr/0024): the tool starts itself on its own physical talk key (the trigger); Hijack only switches back.
    public var follow: Bool
    public var stopOnAnyKey: Bool
    public var holdDelay: Double
    public var restoreTimeout: Double
    public var fallbackDelay: Double

    // A public struct has no public memberwise init; this one keeps the same argument order.
    public init(
        trigger: KeySpec, providerID: String, switchesInput: Bool, voiceID: String, voiceName: String,
        forwardKey: KeySpec, style: String, toggle: Bool, follow: Bool = false, stopOnAnyKey: Bool, holdDelay: Double,
        restoreTimeout: Double, fallbackDelay: Double
    ) {
        self.trigger = trigger; self.providerID = providerID; self.switchesInput = switchesInput
        self.voiceID = voiceID; self.voiceName = voiceName; self.forwardKey = forwardKey; self.style = style
        self.toggle = toggle; self.follow = follow; self.stopOnAnyKey = stopOnAnyKey; self.holdDelay = holdDelay
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
    public var sampled: Bool = false  // the 0.3 s sample after the talk key went out ran (hold style only)
    // W10: other processes' filtering key listeners ahead of ours at that sample (nil: not sampled or unreadable).
    public var ahead: [String]?
    public var heldProcess: ProcessState?  // W9: App Nap state at the same 0.3 s sample (nil: not sampled or unreadable)
    public var switchFailed: Bool = false  // the input source never switched: the talk key was not sent (FM-05)
    public var follow: Bool = false  // W11: the tool took the physical key itself; nothing was switched in or posted
    public var chained: Bool = false  // W11: pressed while the previous dictation's restore was still pending (FM-17)
    public var toolStarted: Bool = false  // W11: began on the tool's own switch-in, no key of ours seen
    public var sawMic: Bool = false  // W11: the tool's microphone read "on" at some point during the watch
    public var toolDoneMs: Int?  // W11: watch start → the tool's last live signal went (window closed, or mic off)
    public var toolDoneBy: String = "window"  // W11: which signal ended the watch: "window" | "mic"
    public var toolGaveUp: Bool = false  // W11: the tool still read live at maxToolDictation
}

public final class Engine {
    public let makePlan: () -> Plan
    public let keys: KeyPoster
    public let sources: InputSources
    public let tap: TapControl
    public let probes: Probes
    public let clock: Scheduler
    public let sink: Sink
    public let supervisor: Supervisor

    /// W8: a dictation held at least this long, whose talk key went out, is judged on its echo and post probe.
    public static let relaunchMinHold: TimeInterval = 0.5
    /// W8: at most one self-relaunch per this many seconds, persisted across restarts.
    public static let relaunchGap: TimeInterval = 600

    public private(set) var plan: Plan
    public var previous: String?  // the input source to restore after this dictation
    /// W11: the most recent current input source that is not the voice source, kept from the system's change
    /// notifications (and the start). Follow mode restores to it when the dictation began inside the voice source
    /// or on the tool's own switch-in, where no press told us where the user came from.
    public var lastOtherSource: String?
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
        supervisor = deps.supervisor
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

    public func post(_ key: KeySpec, down: Bool) {
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
        // W7: staleness flaps inside a degraded run (echo seen, then missing 10 s later, no sleep between),
        // so the source is replaced before every dictation's press, not only after sleep or idle.
        keys.rebuild(reason: "dictation")
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
        var sourceAtPress: String?  // read once per press, only when the answer decides the mode (ADR 0011)
        if event == .press {
            // The shortcut is the tool's own key and the tool is already in front: it gets the real key.
            let sameKey = p.trigger == p.forwardKey && !p.toggle && p.style == "hold"
            let follow = p.follow && !p.toggle
            // One TIS read, and only for a same-key or follow press of an input method: a toggle press or a hold
            // press with its own shortcut never needed it and still does not (review round 1, M2).
            if (sameKey || follow) && p.switchesInput { sourceAtPress = sources.current() }
            let inVoice = !p.switchesInput || sourceAtPress == p.voiceID
            // W11: in follow mode a press inside the voice source is passthrough only when no restore is pending;
            // with one pending (a press while waiting for the previous text) the dictation chains and keeps `previous`.
            // Inside the voice source with a source to go back to (pending from the previous dictation, or the tracked
            // last other source), a follow press is a dictation that restores to it: the user is in the voice source
            // because a restore was missed, or because the tool switched in by itself. An app has no source at all.
            let restorable = p.switchesInput && (previous != nil || lastOtherSource != nil)
            mode = SessionMode(
                toggle: p.toggle, switchesInput: p.switchesInput,
                passthrough: follow ? inVoice && !restorable : sameKey && inVoice, follow: follow)
        }
        let before = machine.state
        let effects = machine.handle(event, mode)
        let after = machine.state
        trace("\(event.rawValue): \(before.rawValue) → \(after.rawValue) \(effects.map { "\($0)" })")
        if (before == .starting || before == .listening || before == .following)
            && (machine.state == .waitingForText || machine.state == .idle)
        {
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
            case .finishPrevious:  // the retry after a failure must not erase it
                summary(end: event == .toolStarted ? "the tool switched itself in, followed from here" : "interrupted by the next press")
            case .begin:
                generation += 1; record = DictationRecord(pressedAt: clock.now); voicePIDs = []; micOffSince = nil; beginDictation()
                record.follow = mode.follow; record.toolStarted = event == .toolStarted
            case .rememberSource:
                // W11: the tool switches itself in; we only keep where to come back to: the source at the press when it
                // was another one, else the tracked last other source (a press inside the voice source, or no press at
                // all). The mic and window samples still run (off-main), so the line can say whether the tool took the key.
                record.chained = previous != nil && (sourceAtPress == nil || sourceAtPress == p.voiceID)
                if let cur = sourceAtPress, cur != p.voiceID {
                    previous = cur
                } else if previous == nil, let last = lastOtherSource {
                    previous = last
                }
                enterPhase("following"); report("listening", p.voiceName)
                // The tool's processes, for the samples: listing running apps asks other processes, so after the
                // tap returns (ADR 0011), as sendKey() does from its scheduled turn.
                let gen = generation
                clock.after(0) { [self] in
                    guard gen == generation, voicePIDs.isEmpty else { return }
                    voicePIDs = probes.processIDs(ofProvider: p.providerID)
                }
                sampleWhileHeld(gen: gen, after: 0.3)
            case .switchToVoice:
                let cur = sourceAtPress ?? sources.current()  // a same-key press already read it for the mode decision
                if let cur, cur != p.voiceID { previous = cur }
                // After the tap returns: nothing slow inside the tap, every tap after ours would wait for it.
                if cur != p.voiceID { clock.after(0) { [self] in switchTo(p.voiceID, "switch to") } }
                report("switching", p.voiceName)
            case .scheduleTalkKey: scheduleTalkKey()
            case .sendTalkKey: sendKey()
            case .releaseTalkKey: endVoice()
            case .waitForText: report("finishing", p.voiceName); waitForText()
            case .watchTool: report("finishing", p.voiceName); watchTool()
            case .finish: finish()
            }
        }
        // Back in idle without a finish (a passthrough release after an interrupted dictation, a quit): the source
        // remembered for that dictation is stale now. Left in place, a later follow-mode press inside the voice
        // source would read it as a pending restore and switch back to it (review round 1, M2).
        if machine.state == .idle, before != .idle, !effects.contains(.finish), previous != nil {
            trace("dropping the remembered input source \(self.previous ?? ""): back in idle without a finish")
            previous = nil
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
            // Follow mode only gets here when the source could not be read at the press (inside the voice source it
            // is passthrough and never finishes); hold mode when the dictation started inside the voice source.
            summary(
                end: record.follow
                    ? "input source unreadable at the press, nothing to switch back to"
                    : "started inside \(p.voiceName), nothing to switch back to")
            report("done", p.voiceName); return
        }
        // W11 (review round 2): a tap or a chord on the talk key is the Globe key too. If it switched the input source
        // (macOS "Change Input Source" on Fn) and no voice window was seen, that switch is the user's own: leave it.
        // Hijack switched nothing in, so there is nothing of ours to undo. A chained press keeps the pending restore.
        // The same for the tool's own switch-in with nothing live after it: a manual switch to the voice source.
        let held = (record.releasedAt ?? clock.now).timeIntervalSince(record.pressedAt)
        if record.follow, held < p.holdDelay || record.toolStarted, !record.sawWindow, !record.sawMic, !record.chained {
            summary(end: "input source left alone"); report("done", ""); return
        }
        guard sources.current() == p.voiceID else {
            // W11: in follow mode the tool may simply not have taken the key: then nothing changed and nothing is switched.
            let stayed = record.follow && sources.current() == prev
            summary(end: stayed ? "input source stayed, nothing to switch back" : "input source already changed, not switched back")
            report("done", ""); return
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

    /// W11: after the tool's microphone goes off, wait this long for its final text (its window, when it shows one,
    /// closes after the final text; the mic can stop before recognition ends). Field value pending.
    public static let micGrace = 1.0
    /// W11: the longest a tool-driven follow dictation is watched. A stuck live reading (another app holding the mic,
    /// a window that never closes) ends here, and the line says `gave up`.
    public static let maxToolDictation = 60.0

    /// W11: follow mode's end signal, in place of the key-path window watch. The tool's voice window, when it shows
    /// one, says when the text is in (ADR 0003); when it shows none, its microphone does, with `micGrace`. Nothing
    /// live within `fallbackDelay` from the start is a manual switch to the voice source (finish leaves it alone).
    /// The probes (window list, CoreAudio) run off the main thread, every 0.1 s.
    public func watchTool() {
        let p = plan, gen = generation, began = record.releasedAt ?? clock.now
        var liveSince: Date?, liveGone: Date?, byWindow = false
        func poll() {
            guard gen == generation, machine.state == .waitingForText else { return }
            if voicePIDs.isEmpty { voicePIDs = probes.processIDs(ofProvider: p.providerID) }
            let pids = voicePIDs, probes = probes
            clock.offMain({ () -> (WindowState, Bool?, Bool?) in
                (probes.windows(of: pids), probes.micInUse(by: pids), probes.micInUse(by: nil))
            }) {
                [self] window, micTool, micDevice in
                guard gen == generation, machine.state == .waitingForText else { return }
                let now = clock.now, waited = now.timeIntervalSince(began)
                if window.busy == true { record.sawWindow = true; byWindow = true }
                if micTool == true { record.sawMic = true }
                if record.toolStarted {  // no held samples ran: the line's mic and window fields come from the watch, best reading kept
                    record.heldMic = (record.sawMic || micTool == true ? true : micTool, micDevice)
                    if window.busy == true || record.heldWindow?.busy != true { record.heldWindow = window }
                }
                // A window seen once is the better signal: from then on the mic no longer keeps the dictation live.
                let live = byWindow ? window.busy == true : window.busy == true || micTool == true
                if live {
                    liveSince = liveSince ?? now; liveGone = nil
                } else if liveSince != nil, liveGone == nil {
                    liveGone = now; record.toolDoneMs = ms(since: began); record.toolDoneBy = byWindow ? "window" : "mic"
                    mark("tool done")
                }
                let grace = byWindow ? capsuleGrace : Engine.micGrace
                let done = liveGone.map { now.timeIntervalSince($0) >= grace } ?? false
                let gaveUp = liveSince == nil ? waited >= p.fallbackDelay : waited >= Engine.maxToolDictation
                guard done || gaveUp else { clock.after(0.1) { poll() }; return }
                if gaveUp, liveSince != nil, liveGone == nil { record.toolGaveUp = true }
                self.waited = waited
                run(.textDone)
            }
        }
        clock.after(0.05) { poll() }
    }

    /// W11: the system's selected input source changed; the app forwards TIS's notification on the main queue, never
    /// from the tap callback. Keeps the last source that is not the voice one. In follow mode a switch INTO the voice
    /// source is the tool starting itself (we never select it in that mode): the one signal left when its key
    /// listener swallows the physical talk key. A burst of notifications for one switch starts one dictation.
    public func inputSourceChanged() {
        let p = plan
        guard let id = sources.current() else { return }
        if id != p.voiceID {
            if lastOtherSource != id { trace("input source now \(id)") }
            lastOtherSource = id; return
        }
        guard p.follow, !p.toggle, p.switchesInput else { return }
        if machine.state == .waitingForText, record.toolStarted { return }  // the same switch-in, reported again
        mode = SessionMode(toggle: false, switchesInput: true, passthrough: false, follow: true)
        run(.toolStarted)
    }

    /// While the talk key is held: is the voice tool listening, and is its window up? Sampled every half
    /// second off the main thread (CoreAudio and the window list are slow for a key tap); release keeps the last.
    public func sampleWhileHeld(gen: Int, after delay: Double) {
        clock.after(delay) { [self] in
            guard machine.state == .listening || machine.state == .following, gen == generation else { return }
            // The first sample of a held key also reads App Nap (W9, one Mach call, here) and the key-listener chain
            // (W10, ADR 0023: a window-server call, 2 ms p50 / 12 ms max measured at load 30, so in the off-main
            // block below: the main run loop hosts our tap, and a slow window server must not hold it). Only a held
            // key has a sample at all: a tapped key is over by now. W11: both readings are about a posted key; a
            // follow dictation (`.following`) posted none and reads neither.
            let readChain = !record.sampled && plan.style == "hold" && machine.state == .listening
            if readChain {
                record.sampled = true
                record.heldProcess = probes.processState()
            }
            let pids = voicePIDs, watched = plan.switchesInput, probes = probes, tap = tap, key = plan.forwardKey
            clock.offMain({ () -> ((Bool?, Bool?), WindowState, ChainRead?) in
                let mic = (probes.micInUse(by: pids), probes.micInUse(by: nil))
                let window: WindowState = watched ? probes.windows(of: pids) : .unknown("an app: its window isn't watched")
                let chain = readChain ? ChainRead(ahead: tap.listenersAhead(for: key)) : nil
                return (mic, window, chain)
            }) { [self] mic, window, chain in
                guard gen == generation else { return }
                if let chain {
                    record.ahead = chain.ahead
                    trace("key listeners ahead of ours: \(self.aheadField(chain.ahead))")
                }
                record.heldMic = mic; record.heldWindow = window
                // A sample started before the release can complete after it (review-4 S1): the dictation
                // is already over, so its reading is stale and must not overwrite the UI's post-release text.
                if machine.state == .listening || machine.state == .following {
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

    /// W10: one chain read, carried from the off-main sample to its completion (nil: this sample did not read it).
    struct ChainRead { let ahead: [String]? }

    /// W10: `none`, the names ahead of ours joined by `+`, or `?`. Substrings the stats parser looks for.
    func aheadField(_ a: [String]?) -> String {
        guard let a else { return "?" }
        return a.isEmpty ? "none" : a.joined(separator: "+")
    }
    /// W9: `, nap: on|off|?` and, when it was read, `, role: N`. Substrings the stats parser looks for.
    func napField(_ s: ProcessState?) -> String {
        guard let s else { return ", nap: ?" }
        return ", nap: \(s.napped ? "on" : "off")" + (s.role.map { ", role: \($0)" } ?? "")
    }
    /// W9: ` nap=on|off|?` read now, for the `started:` and `self-relaunch:` lines.
    func napNow() -> String { " nap=" + (probes.processState().map { $0.napped ? "on" : "off" } ?? "?") }

    // The one line per dictation that goes to the file. When it didn't work, the checks tell which step failed:
    // the key never went out (echo), the voice tool didn't start listening (mic), or we missed its window.
    public func summary(end: String) {
        let p = plan, r = record
        let held = (r.releasedAt ?? clock.now).timeIntervalSince(r.pressedAt)
        // review-5 #17: the tool and the key are logged by their stable id, not `.name`/`.voiceName` (both
        // run through `localize`), so a language change does not split one tool into two in `hijack stats`.
        func onOff(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "?" }
        var line = "dictation \(p.providerID) (\(r.follow ? "follow" : p.toggle ? "toggle" : "hold")): "
        line += r.toolStarted ? "switched in by the tool" : "held \(String(format: "%.2f", held))s"
        if r.follow, r.toolStarted || held >= p.holdDelay {
            // W11: nothing was posted, so no `sent`, `echo`, `ahead:` or `nap:`; the window and mic say whether the tool
            // took its key, and which of the two said the text was in.
            let since = r.toolStarted ? "start" : "release"
            if let done = r.toolDoneMs {
                line += ", \(r.toolDoneBy == "mic" ? "mic off" : "window closed") \(done)ms after \(since)"
            } else if r.toolGaveUp {
                line += ", still live \(String(format: "%.0f", Engine.maxToolDictation))s after \(since), gave up"
            } else {
                line +=
                    r.toolStarted
                    ? ", nothing live within \(String(format: "%.2f", p.fallbackDelay))s" : ", window never closed after release"
            }
            line +=
                ", \(end) | mic tool \(onOff(r.heldMic?.tool)) device \(onOff(r.heldMic?.device)), window \(r.toolStarted ? "seen" : "while held"): \(r.heldWindow?.text ?? "?")"
        } else if r.follow {
            // W11: a tap or a chord on the talk key (Fn+Delete, the Globe key) is not a dictation, as a hold-mode press
            // released before the hold delay is not: the line says so and `hijack stats` leaves it unjudged. The
            // window watch and the restore still ran, as they do for a too-short hold-mode press.
            line += ", released before \(p.forwardKey.logID) was held for \(String(format: "%.2f", p.holdDelay))s, \(end)"
        } else if let sent = r.keySentMs {
            line += ", \(p.forwardKey.logID) sent after \(sent)ms"
            if p.switchesInput {
                line += r.windowGoneMs.map { ", window closed \($0)ms after release" } ?? ", window never closed after release"
            }
            line += ", \(end)"
            line +=
                " | echo \(r.echoMs.map { "after \($0)ms" } ?? "missing"), ahead: \(aheadField(r.ahead))\(napField(r.heldProcess)), mic tool \(onOff(r.heldMic?.tool)) device \(onOff(r.heldMic?.device))"
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
        relaunchIfPostFailed(plan: p, record: r, held: held)
    }

    // W8 (docs/adr/0022-relaunch-on-a-failed-post.md): the talk key did not go out of this process: our tap never
    // saw it come back. The only known remedy for a fault inside this process is a fresh one. Runs once per
    // dictation, after its summary line, off the tap callback. Echo seen with the mic off is the voice tool's side
    // and never qualifies. Never while a session is active: that is a newer press that interrupted this summary.
    // W10 (ADR 0023): behind an older process's filtering key listener (one that re-created its tap after ours
    // appeared) the key was taken there, not lost here, and a fresh process would sit behind it again within
    // seconds: no relaunch, one line that says so. An unread chain (nil) does not block the one remedy left.
    func relaunchIfPostFailed(plan p: Plan, record r: DictationRecord, held: TimeInterval) {
        guard p.style == "hold", held >= Engine.relaunchMinHold, r.keySentMs != nil, r.echoMs == nil else { return }
        guard !machine.isActive else { trace("self-relaunch skipped: a session is active"); return }
        let why = "talk key did not go out: echo missing"
        if let ahead = r.ahead, !ahead.isEmpty {
            log("self-relaunch skipped: \(ahead.joined(separator: "+"))'s key listener sits ahead of ours (\(why))")
            return
        }
        let now = clock.now
        if let last = supervisor.lastRelaunchAt {
            let age = now.timeIntervalSince(last)
            if age < Engine.relaunchGap {
                log("self-relaunch suppressed: last one \(Int(max(age, 0) / 60))m ago (\(why))")
                return
            }
        }
        log("self-relaunch: \(why)\(napNow())")
        // Not inline: for an app provider this summary runs inside the CGEventTap callback (ADR 0011), and a quit
        // there would never return the swallowed trigger key-up. The next main-loop turn is outside the callback.
        // The time is stored only when the relauncher started, so a failed spawn does not use up the rate limit.
        let relaunchNextTurn = { [self] in
            guard !machine.isActive else { trace("self-relaunch cancelled: a session started"); return }
            if supervisor.relaunch(reason: why) { supervisor.lastRelaunchAt = clock.now }
        }
        clock.after(0, relaunchNextTurn)
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
        if down == physicalDown { return machine.passesKeyThrough }
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
        if let cur = sources.current(), cur != plan.voiceID { lastOtherSource = cur }  // W11: where a follow dictation goes back to
        clock.after(1) { [self] in clearStuckModifier() }
        log(
            "started: trigger \(plan.trigger.name), forward \(plan.forwardKey.name), voice \(plan.voiceID)"
                + (supervisor.takeSelfRelaunchMark() ? " (after self-relaunch)" : "") + napNow())
    }
}
