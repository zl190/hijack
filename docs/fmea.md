# FMEA: what can go wrong in one dictation, and what the user sees

Failure Mode and Effects Analysis of `Engine` (`Sources/Engine.swift`) and the macOS services it uses.
Read it with `docs/state-machine.md`. The state machine is pure and has tests. This document covers the
effects that `Engine` carries out against macOS. Those paths have no tests.

Date: 2026-10-03. Code: main at 65897a1 (unreleased, after v1.1.3). Signal column checked against
the code by `docs/hci-review-faults.md`; three cells corrected on the same day.

## Method

One row per failure mode. Columns:

- **Function**: which step of a dictation (F1 to F8 below).
- **Failure mode**: what the engine or the system does wrong.
- **Effect**: what the user experiences.
- **Signal**: what the user can see at the moment it happens (menu bar, "Try it" area, nothing). The
  HCI review (`docs/hci-review-faults.md`, next step) grades this column.
- **Detection**: how the log or stats record it today.
- **S / O / D**: severity, occurrence, detection, each from 1 to 5. RPN = S × O × D.
- **Test**: the fault-injection test that covers the row (planned ids FI-1 to FI-4), or "manual".

Severity (S):

| S | Meaning |
|---|---|
| 1 | Cosmetic |
| 2 | The dictation is slower |
| 3 | The dictation is lost. Nothing else happens |
| 4 | Text is lost, or text goes to the wrong place |
| 5 | The keyboard is wrong for every app until the user acts (a stuck modifier, swallowed keys) |

Occurrence (O), from the log of 2026-10-03 only. The log format changed today. One day is thin data.
Score O again after seven days of `hijack stats`.

| O | Meaning |
|---|---|
| 1 | Not seen, and no mechanism known |
| 2 | Mechanism known, not seen |
| 3 | Seen once or twice |
| 4 | Seen in 1 of 10 dictations |
| 5 | Seen in most dictations |

Detection (D):

| D | Meaning |
|---|---|
| 1 | The summary line names it |
| 2 | The summary line implies it |
| 3 | A separate log line records it, with no link to the dictation |
| 4 | Only `hijack log --live` shows it |
| 5 | Nothing records it |

Field data for O (whole log, 2026-10-03 12:56 to 21:27):

| Event | Count |
|---|---|
| Dictations | 20 (+1 released before the key was sent) |
| Text arrived | 20 |
| `event tap was disabled by the system (timeout)` | 2 |
| `slow key event` | 10 (8 another key, 2 the shortcut) |
| `released before ... was sent` | 5 |
| `didn't stick`, `catching up`, `window never closed`, `secure input on`, `key tap disabled` | 0 |

## Functions

| Id | Function | Code |
|---|---|---|
| F1 | See the shortcut's edges | `Engine.start`, `Engine.handle`, the event tap |
| F2 | Switch to the voice input method | `.switchToVoice`, `switchTo`, `currentID` |
| F3 | Send the talk key | `scheduleTalkKey`, `sendKey`, `post`, `postModifier` |
| F4 | Know whether the tool is listening | `sampleWhileHeld`, `micInUse`, `onScreenWindows` |
| F5 | Wait for the text, then switch back | `waitForText`, `finish`, `switchTo(prev)` |
| F6 | Apply settings changes | `SettingsWatch`, `Config.reload`, `Engine.refresh` |
| F7 | Record what happened | `summary`, `log`, `hijack stats` |
| F8 | Stay alive across grant, sleep, lock, restart | `start` (AX polling), `reconcile`, `AppState` |

## Failure modes

| Id | F | Failure mode | Cause | Effect | Signal | Detection | S | O | D | RPN | Test |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FM-01 | F1 | Tap disabled while the shortcut is held (hold mode); the release is missed | Main thread stalled past the WindowServer timeout (slow TIS/AX/window-list call, SwiftUI); or the user dragged | Talk key stays posted: the modifier is held for every app until the next shortcut edge. `reconcile` catches it only if the tap gets re-enabled and `keyState` says up | None while stuck. Modifier behaves as held | `event tap was disabled`, then `catching up` (3) | 5 | 3 | 3 | 45 | FI-1 |
| FM-02 | F1 | Tap re-enable fails after `tapDisabledByTimeout` | `tapEnable` returns without effect (not checked) | Shortcut dead for every dictation; other keys pass | None until the user tries | `key tap disabled` on the next summary, which never comes (no dictation starts) | 5 | 2 | 4 | 40 | FI-1 |
| FM-03 | F1 | Secure Event Input on (password field, some apps) | Another process holds secure input | Tap sees no key events: the shortcut does nothing, in every app, until that process releases it | None | `secure input on` on a summary line, only if a dictation runs | 4 | 2 | 3 | 24 | manual |
| FM-04 | F1 | Shortcut repeat or release arrives with `physicalDown` out of sync | Edge missed before `reconcile`; toggle mode is excluded from reconcile | Release passed through as a bare modifier key-up, or press swallowed | None | `catching up` (3) | 3 | 3 | 3 | 27 | FI-1 |
| FM-05 | F2 | `select(voiceID)` fails or does not stick | TIS refused; input source removed; another IME switcher | Talk key sent to the wrong input source after `maxSwitchWait` (1 s): Fn alone opens the macOS dictation or emoji picker, Option alone does nothing | Try it shows "switching", then "Listening…" after the key goes out; no error | `didn't stick, retry` (3), `input source not ready after ... sending anyway` (4) | 4 | 2 | 3 | 24 | FI-2 |
| FM-06 | F2 | Switch slow but under 1 s | TIS slow after wake, first switch in a while | Talk key late; held time short; text may be cut | Try it shows "switching" longer | `sent after Nms` on the summary (1) | 2 | 3 | 1 | 6 | FI-2 |
| FM-07 | F2 | Shortcut pressed while already in the voice method; `previous` from an earlier dictation is kept | `previous` only updated when `cur != voiceID` | `finish` switches to the input source of the *last* dictation, not where the user was | Menu bar input source changes unexpectedly | Not distinguished from a normal restore (5) | 3 | 3 | 5 | 45 | FI-2 |
| FM-08 | F3 | `CGEvent(keyboardEventSource:...)` returns nil | Resource failure, very rare | No talk key; machine still goes to `listening`; release posts nothing either | Try it says "listening" but nothing listens | `couldn't create ...` (3) and `echo missing` (1) | 3 | 1 | 1 | 3 | FI-4 |
| FM-09 | F3 | Talk key posted but another tap or the IME ignores it | A later head-insert tap (Karabiner, another remapper); IME in a state that drops Fn; stale implicit event source after a long run (review-3 H3) | Nothing listens; user talks to nobody | Try it "listening" | `echo missing` or echo present with `mic tool off` (1) | 3 | 2 | 1 | 6 | FI-4 |
| FM-10 | F3 | Process killed or crashes between `startVoice` and `endVoice` | Crash, `kill -9`, logout | Modifier left down system-wide; next start does not release it | Keyboard wrong in every app | Nothing (5) | 5 | 2 | 5 | 50 | FI-4 |
| FM-11 | F3 | Hold shorter than `holdDelay` (0.2 s) | A tap instead of a hold | No dictation; by design | Nothing | `released before ... was sent` (1) | 1 | 4 | 1 | 4 | covered (machine) |
| FM-12 | F4 | Mic probe returns nil or wrong | macOS < 14.2 per-process API; sample taken before the IME opens the mic | `cause` in stats misattributed (`toolDidntListen` vs `windowNotSeen`) | None (diagnostic only) | The summary shows `mic tool ?` (1) | 1 | 3 | 1 | 3 | FI-3 |
| FM-13 | F4 | Window probe counts an unrelated window of the IME process (candidate bar, settings) | `onScreenWindows` counts any on-screen window of the pid | `sawWindow` true; restore waits for the bar to go or `restoreTimeout` (5 s) | Switch back visibly late | `window closed Nms` large, or `window never closed` (1) | 2 | 3 | 1 | 6 | FI-3 |
| FM-14 | F5 | Voice window never closes within `restoreTimeout` | Slow network, IME still transcribing | Hijack switches back while the text is uncommitted: the text is dropped | Input source flips back; text vanishes | `window never closed after release` (1) | 4 | 2 | 1 | 8 | FI-3 |
| FM-15 | F5 | No window ever seen; `fallbackDelay` (2.5 s) elapses | IME helper not running; `processIDs` empty; window off-screen | Switch back too early (text dropped) or too late (user types into the IME) | Same as FM-14 | `window while held: not running` (1) | 4 | 2 | 1 | 8 | FI-3 |
| FM-16 | F5 | `switchTo(prev)` fails | TIS refused; `prev` removed from the enabled sources | User left in the voice IME; next typing goes through WeType | The macOS input menu shows the IME; no Hijack surface | `restore ... didn't stick` (3) | 3 | 2 | 3 | 18 | FI-2 |
| FM-17 | F5 | Next press during `waitingForText` | Fast second dictation | Previous summary written as "interrupted"; its restore skipped, the new one restores to the older `previous` | Fine when the chain completes | `interrupted by the next press` (1) | 2 | 3 | 1 | 6 | covered (machine) |
| FM-18 | F6 | Config folder absent at launch | First run before any save | FSEvents never watches `~/.config/hijack`; edits by hand are not applied until restart | None | None (5) | 2 | 2 | 5 | 20 | unit (Watch) |
| FM-19 | F6 | Config unparsable after a hand edit | JSON error | Previous values kept; saving blocked | Menu shows the error state | `config: can't parse` (3) | 2 | 2 | 3 | 12 | covered (Config) |
| FM-20 | F6 | Voice tool's settings change while a dictation runs | WeType key rebound mid-hold | `refresh` deferred until idle, by design; no failure | None | `trace` only (4) | 1 | 1 | 4 | 4 | covered |
| FM-21 | F6 | WeType MMKV layout changes | WeType update | Detected key nil; forward key falls back to right Option; WeType ignores it | Settings window shows a detected key that is wrong or absent | `echo` present, `mic tool off` (2) | 3 | 2 | 2 | 12 | unit (Providers) |
| FM-22 | F7 | Log write fails or rotates mid-line | Disk full; app and CLI racing on rotation | Lines lost; stats under-count | None | None (5) | 1 | 2 | 5 | 10 | unit (log) |
| FM-23 | F7 | A superseded dictation leaves a misleading summary | `finishPrevious` writes "interrupted" with stale probes | `hijack stats` counts it as a failure or success wrongly | None | The line itself (1) | 1 | 3 | 1 | 3 | unit (Stats) |
| FM-24 | F8 | Accessibility not granted, or revoked after an update | New binary signature; user reset privacy | Tap never installs; `start` polls every 1 s forever | The menu reads `AXIsProcessTrusted()` and shows the grant step | `AppState.trusted false` (3) | 4 | 3 | 2 | 24 | manual |
| FM-25 | F8 | Sleep or lock during `listening` or `waitingForText` | Lid closed mid-dictation | Talk key held through sleep; after wake the IME and TIS state are unknown; `reconcile` only runs after a tap timeout | Keyboard possibly wrong after wake | `system sleep` / `system wake` lines (3), no tie to the dictation | 4 | 2 | 3 | 24 | FI-1 |
| FM-26 | F8 | Slow key event: the tap spends > 100 ms on a key | Main thread busy (settings window live refresh at 1 Hz, window list, TIS) | Every key on the system lags; repeated stalls lead to FM-01 | Typing feels sticky | `slow key event (...)` (3) | 3 | 4 | 3 | 36 | FI-1 (timing) |

## Ranked

| RPN | Id | One line |
|---|---|---|
| 50 | FM-10 | Crash while the talk key is held leaves a modifier down system-wide; nothing clears it on restart |
| 45 | FM-01 | Tap timeout during a hold misses the release; the talk key stays posted |
| 45 | FM-07 | `previous` is stale when the dictation starts inside the voice IME; restore goes to the wrong source |
| 40 | FM-02 | Tap re-enable is not verified |
| 36 | FM-26 | Slow key events, 10 today in 20 dictations, are the precursor of FM-01 |
| 27 | FM-04 | Edge desync outside hold mode is not reconciled |
| 24 | FM-03, FM-05, FM-24, FM-25 | Secure input, failed switch, no Accessibility, sleep mid-dictation |

## Actions

Each action names the row it closes and the test that verifies it.

1. **Release a stuck modifier at start** (FM-10, S5). At `start`, read `CGEventSource.flagsState(.hidSystemState)`. If the forward key's modifier is down and `physicalDown` is false, post the release. Log `cleared a stuck <key>`. Test: FI-4 posts a down, drops the engine, and starts a new engine with a fake flags state that says down. It asserts one release.
2. **Check the re-enable** (FM-02, FM-01). After `tapEnable`, read `tapIsEnabled`. If it is false, retry on the next run-loop turn and write `AppState.tapActive = false`, so that the menu shows it. Test: FI-1 uses a tap control whose enable fails once.
3. **Stop the session on wake and on unlock** (FM-25, FM-04). Today `reconcile()` runs only after a tap timeout, and only for hold mode. On `didWake` and `screenIsUnlocked`, stop any active session: hold mode as a release, toggle mode as a press. The tap-timeout `reconcile()` stays as it is. In toggle mode a key-up during `listening` is normal, so it is not a fault signal. Test: FI-1 drives wake and unlock in each active state.
4. **Reset `previous` for each dictation** (FM-07). Set `previous = nil` on `.begin`. When `cur == voiceID` at press, there is no source to restore. `finish` must log that. Test: FI-2 presses twice from inside the voice IME and asserts no restore switch.
5. **Do not send the talk key to the wrong source** (FM-05, S4). When `maxSwitchWait` passes and the source is still wrong, do not send the key. Finish with `input source never switched`. The user loses one dictation. macOS dictation does not start. Test: FI-2 uses a fake input source that never changes.
6. **Watch the config folder before it exists** (FM-18). Watch the parent folder that exists (`~/.config`) with file-level events, or create the folder at launch. Test: a unit test on `SettingsWatch` with a temporary folder.
7. **Score O again after seven days** of `hijack stats` on the 1.1.4 build. The O column today rests on 20 dictations.

Rows with no action, recorded only:

- FM-03: macOS owns secure input. The HCI review decides if the menu shows it.
- FM-12, FM-13: probe accuracy. See review-3, findings 5 and 6.
- FM-22, FM-23: logging. Low severity.

## What has to be injectable

The four fault-injection groups need these seams in `Engine`. Each seam is a protocol with a live implementation and a fake one.

| Seam | Today | Used by |
|---|---|---|
| `KeyPoster` | `post`, `postModifier` call `CGEvent...post` | FI-4 |
| `InputSources` | `currentID()`, `select(_:)`, `switchTo` | FI-2 |
| `TapControl` | `CGEvent.tapIsEnabled`, `tapEnable`, `CGEventSource.keyState`, `flagsState` | FI-1 |
| `Probes` | `onScreenWindows`, `micInUse`, `provider.processIDs()` | FI-3 |
| `Scheduler` | `DispatchQueue.main.asyncAfter` in `scheduleTalkKey`, `waitForText`, `sampleWhileHeld`, `tapKey` | FI-1 to FI-4 (a fake clock advances time by hand) |
| `Sink` | `log`, `report`, signposts | assertions on the summary line |

`Engine` moves to `Sources/Core`, inside the package, so that `swift test` can reach it. `build.sh` compiles the
same file as before. AppKit code (`NSWorkspace`, `TIS`, `CoreAudio`, `CGEvent`) stays in `Sources/`, behind the seams.

## Fault-injection groups

| Id | Faults injected | Rows | Assertions |
|---|---|---|---|
| FI-1 | Tap disabled during `listening`; re-enable fails once; release never arrives; wake observed | FM-01, 02, 04, 25, 26 | One talk-key release posted; state returns to `idle`; `catching up` logged; `tapActive` reflects the failed enable |
| FI-2 | `select` returns false; `currentID` never changes; `currentID` already equals `voiceID`; `select(prev)` fails | FM-05, 06, 07, 16 | No talk key after `maxSwitchWait`; no restore to a stale `previous`; summary names the step |
| FI-3 | Window never seen; window seen then never closes; `processIDs` empty; mic probe nil | FM-12, 13, 14, 15 | Restore at `fallbackDelay` or `restoreTimeout` exactly (fake clock); summary carries `window never closed` |
| FI-4 | `KeyPoster` fails once; echo never arrives; engine dropped mid-hold and recreated with the modifier shown down | FM-08, 09, 10 | `couldn't create` logged; machine still releases; a new engine clears the stuck modifier once |

Each group is one test file under `Tests/HijackCoreTests/`. Each test covers one row. A failing test names
the FMEA row.
