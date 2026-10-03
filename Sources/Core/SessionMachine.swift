// MARK: dictation state machine — what a key press does, decided in one place (docs/state-machine.md).
// Pure: no AppKit, no timers, no I/O, so the tests can drive every state with every event.

enum SessionState: String, CaseIterable {
    case idle
    case passthrough
    case starting
    case listening
    case waitingForText
}

enum SessionEvent: String, CaseIterable {
    case press        // the shortcut went down
    case release      // the shortcut went up
    case otherKey     // another key, while a toggle session runs and "any key stops" is on
    case keySent      // the input source is ready: send the talk key
    case textDone     // the voice window went, or the wait timed out
}

/// What the current press is: fixed for the press, read by the engine before it hands the event over.
struct SessionMode: Equatable {
    var toggle: Bool = false          // tap to start, tap to stop
    var switchesInput: Bool = true    // an input method (switch to it and back); false: an app with its own hotkey
    var passthrough: Bool = false     // the shortcut is the tool's own key and the tool is already active
}

enum SessionEffect: Equatable {
    case passKey                  // let the key event through
    case swallowKey               // drop the key event
    case swallowKeyAndItsRelease  // drop it, and its key-up later (a key that stopped a toggle session)
    case finishPrevious           // the previous dictation is still waiting for its text: write it up now
    case begin                    // a new dictation
    case switchToVoice            // select the voice input method
    case scheduleTalkKey          // send the talk key once the switch is ready (and the hold delay is over)
    case sendTalkKey
    case releaseTalkKey
    case waitForText              // watch the voice window, then report textDone
    case finish                   // summary line; an input method also switches back
}

struct SessionMachine {
    private(set) var state: SessionState = .idle

    var isActive: Bool { state == .passthrough || state == .starting || state == .listening }

    mutating func handle(_ event: SessionEvent, _ mode: SessionMode) -> [SessionEffect] {
        let (next, effects) = SessionMachine.transition(state, event, mode)
        state = next
        return effects
    }

    /// The whole behavior as one function of (state, event, mode). The tests enumerate it into the state diagram.
    static func transition(_ s: SessionState, _ e: SessionEvent, _ mode: SessionMode) -> (SessionState, [SessionEffect]) {
        func start(_ prefix: [SessionEffect] = []) -> (SessionState, [SessionEffect]) {
            if mode.passthrough && !mode.toggle { return (.passthrough, prefix + [.passKey]) }
            return (.starting, prefix + [.swallowKey, .begin] + (mode.switchesInput ? [.switchToVoice] : []) + [.scheduleTalkKey])
        }
        // Stop a running session. `keyEffect` is what happens to the key event that stopped it.
        func stop(_ keyEffect: SessionEffect) -> (SessionState, [SessionEffect]) {
            let release: [SessionEffect] = s == .listening ? [.releaseTalkKey] : []
            return mode.switchesInput ? (.waitingForText, [keyEffect] + release + [.waitForText])
                                      : (.idle, [keyEffect] + release + [.finish])
        }
        switch (s, e) {
        case (.idle, .press):                 return start()
        case (.waitingForText, .press):       return start([.finishPrevious])
        case (.passthrough, .release):        return (.idle, [.passKey])
        case (.starting, .keySent):           return (.listening, [.sendTalkKey])
        case (.starting, .release), (.listening, .release):
            return mode.toggle ? (s, [.swallowKey]) : stop(.swallowKey)
        case (.starting, .press), (.listening, .press):
            return mode.toggle ? stop(.swallowKey) : (s, [.swallowKey])           // hold: a repeat, swallowed
        case (.starting, .otherKey), (.listening, .otherKey):
            return mode.toggle ? stop(.swallowKeyAndItsRelease) : (s, [.passKey])
        case (.waitingForText, .textDone):    return (.idle, [.finish])
        case (.idle, .release), (.waitingForText, .release):
            return (s, [.swallowKey])                                              // toggle: the tap that stopped it
        case (.passthrough, .press):          return (s, [.passKey])
        case (_, .otherKey):                  return (s, [.passKey])
        case (_, .keySent), (_, .textDone):   return (s, [])                       // stale: from an earlier dictation
        }
    }
}
