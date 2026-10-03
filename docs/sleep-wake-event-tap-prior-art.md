# Long-running Hijack stops starting WeType voice: prior art and plan

Research date: 2026-10-03. Read-only investigation. No code was changed.

## 0. Local evidence

What this machine's logs show, before the web research.

| Fact | Evidence | What it means |
|---|---|---|
| The failing process and the fresh processes ran **the same binary** | `/Applications/Hijack.app/Contents/MacOS/Hijack` mtime `Oct 1 21:45:42`. `installed-binary` stamp `709226345:1790855142` = the same mtime. The failing process logged `started:` at 21:46:45. | Rules out a code difference and a TCC/code-signature change (the designated requirement is `certificate root = H"eb76…"`, which is stable). The fault is **state inside the process**. |
| WeType's main process **never restarted** | `WeType` pid 912, started `Thu Sep 24 12:09:30` | The idea that "`runningApplications` holds a stale pid after the IME relaunched" is **refuted** for the main process. It could still apply if the voice window belongs to some other helper process, but none is configured for WeType. |
| In the long-running process, window detection **never** returned `true` | `Hijack.log` lines 428–516: every restore is `restore after ~25xxms` (the `fallbackDelay` path) and there are no `voice window gone` lines. After the 14:59:45 relaunch, every session logs `voice window gone after …ms`. | Both remaining hypotheses fit: the Fn post had no effect, or the window list call returned nothing for WeType's pid. |
| There was **no valid attempt before the first sleep** | The first two triggers in that process (`20:23:09`, `13:11:00`) show `held 0s`. One was `released before forward`, so Fn was never posted. The first real holds were at 14:55 on Oct 3. `pmset -g log` shows no Sleep/Wake between Oct 1 21:46 and Oct 2 22:33. After that it shows a clamshell sleep, about 30 DarkWake/Maintenance cycles from Deep Idle, and FullWakes at 09:52, 10:27 and 12:16. | The link to sleep **cannot be confirmed**. The process may have been broken from launch. |
| Hijack's log has no date and conflates states | `log()` uses the format `HH:mm:ss.SSS`. `isBusy()` returns `nil` when no pid is found and `false` when there is no window, and the restore loop treats both the same way. | These are the two biggest gaps in attributing the failure (see §4). |
| The unified log does not keep this | `log show` around 14:55 and 15:00 returned 0 lines for WeType/Hijack | There is no external record of whether WeType actually started recording. |

## 1. Known macOS issues with event taps or posted events after sleep, lock, user switching, or long uptime

| # | Finding | Source | Status |
|---|---|---|---|
| 1a | Event taps "intermittently stop functioning" after wake. The fix observes `NSWorkspace.didWakeNotification`, waits **1.5 s**, tears the engines down, calls `CFMachPortInvalidate` on the old tap, and recreates it. | [augustobott/winman PR #17](https://github.com/augustobott/winman/pull/17) | Practitioner fix. No root cause from Apple. |
| 1b | Hammerspoon `hs.eventtap` (and other watchers) stop responding after sleep or overnight hibernation. Reloading the config fixes it (#3294, #1798, #1507). In #1502 not even a reload helped, only a reboot. No maintainer root cause. | [#3294](https://github.com/Hammerspoon/hammerspoon/issues/3294), [#1798](https://github.com/Hammerspoon/hammerspoon/issues/1798), [#1507](https://github.com/Hammerspoon/hammerspoon/issues/1507), [#1502](https://github.com/Hammerspoon/hammerspoon/issues/1502) | User reports. Symptom-level only. |
| 1c | Disabling a tap without calling `CFMachPortInvalidate` leaks taps inside WindowServer (2,378 orphaned taps in one long session, high WindowServer CPU in `add_event_vector_to_tap`). | [HD838A/remote-mic-app #476](https://github.com/HD838A/remote-mic-app/issues/476) | Reproduced by the reporter. Relevant to the "recreate on wake" pattern. |
| 1d | macOS disables a tap (`tapDisabledByTimeout` / `ByUserInput`). If the app ignores that event, or keeps its own modifier bookkeeping, shortcuts silently stop until the app restarts. This was Handy's bug in v0.7.4 / handy-keys 0.2.0. | [cjpais/Handy #840](https://github.com/cjpais/Handy/issues/840), [jedipunkz/UnNatural #25](https://github.com/jedipunkz/UnNatural/issues/25) | Confirmed root cause in Handy. Hijack already re-enables on these events. |
| 1e | **Fn/Globe sent with `CGEventPost` is not equivalent to the physical Fn key.** Fn alone does not trigger the system "Press 🌐 key to" action, and fn+ctrl+arrow tiling does not work. Karabiner uses a DriverKit virtual HID keyboard for this reason. | [Karabiner-Elements DEVELOPMENT.md](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md), [Apple forum 766200 (FB15532267)](https://developer.apple.com/forums/thread/766200), [feedback-assistant #524 (FB9093710)](https://github.com/feedback-assistant/reports/issues/524) | Documented by Karabiner. Apple FBs are still open. WeType clearly accepts posted Fn in a fresh process, so this explains a fragile path, not this bug. |
| 1f | After **Secure Event Input** ends, "the pressed-key state may suddenly differ from what it was when Secure Event Input began". Taps cannot see keys while it is on. | Karabiner DEVELOPMENT.md (above) | Documented. A lock screen password field turns Secure Input on. |
| 1g | Secure Event Input can **stay on after unlock** (Codex held `kCGSSessionSecureInputPID` until logout). Tap-based tools then fail system-wide. | [openai/codex #40235](https://github.com/openai/codex/issues/40235) | Confirmed by `ioreg`. **Does not fit here**: a fresh Hijack worked, so the state was not system-wide. |
| 1h | Third-party IMEs are disabled on lock/sleep when Secure Input sticks (`ioreg -l -w 0 \| grep SecureInput`). | [yahoo-keykey-2 #134](https://github.com/teddychan/yahoo-keykey-2/issues/134) | User report. This is also a system-wide effect, so it does not fit a fresh-process fix. |
| 1i | Input-source-dependent state is not re-evaluated after wake until a real input-source change happens. BTT fixed this in 6.706. | [folivora community 47542](https://community.folivora.ai/t/conditional-activation-group-with-keyboard-input-source-condition-stays-inactive-after-wake-from-sleep-btt-restart-until-a-real-input-source-change-event/47542) | Developer-acknowledged fix. This is the same pattern: per-process cached state goes stale across wake. |
| 1j | On macOS sleep the CPU is suspended, and the machine wakes spontaneously (DarkWake/maintenance). Apps get run time and may be put in App Nap. | [Apple forum 795461 (Quinn)](https://developer.apple.com/forums/thread/795461) | Apple DTS. It explains the roughly 30 DarkWakes seen here. |

**Event source state: `nil` vs `.hidSystemState` vs `.combinedSessionState`.** In Apple's terms, `combinedSessionState` combines all event sources posting into the login session, and `hidSystemState` reflects the hardware (HID) sources only ([CGEventSourceStateID](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid); paraphrase at [transxcode mirror](http://transxcode.com/API-FolOPQR/REF_S/SPI_C/CGEventSourceStateID.html)). With a `nil` source, the event gets default fields and does not track key state through an owned source object. **No source found shows that `nil` vs `.hidSystemState` changes whether a posted Fn survives sleep/wake (unverified).** The forum thread on posting fn+ctrl+arrow (766200) used `nil` and failed, but the cause there was the Fn usage mismatch, not the source.

## 2. How mature tools handle this (2024–2026)

| Tool | Mechanism | Wake handling | Watchdog / restart | Source |
|---|---|---|---|---|
| Hammerspoon | `hs.eventtap` (CGEventTap) | Nothing automatic. Users add `hs.caffeinate.watcher` (`systemDidWake`, `screensDidUnlock`) to restart taps, plus a 30 s `isEnabled()` timer as a safety net | Config reload is the user workaround | [eshlox 2026-03](https://eshlox.net/capslock-super-key), [hs.caffeinate.watcher docs](https://www.hammerspoon.org/docs/hs.caffeinate.watcher.html), issues in §1b |
| Karabiner-Elements | IOKit/HID grabber plus a DriverKit virtual HID keyboard; deliberately avoids CGEventTap/CGEventPost | Not needed for posting, because a virtual device behaves like hardware (Fn included) | Daemons run under launchd (KeepAlive) | [DEVELOPMENT.md](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md), [VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice) |
| BetterTouchTool | Closed source | Fixed "not re-evaluated after wake" for input-source conditions (6.706, Aug 2026) | Unknown | §1i |
| Raycast, Rectangle | Closed or not tap-centric | **Not found / unverified** | — | — |
| Handy | handy-keys CGEventTap | Root cause was tap-disable handling plus modifier-state desync. Restarting the app was the workaround | No | [#840](https://github.com/cjpais/Handy/issues/840) |
| VoiceInk | Hotkey plus overlay | A sleep/wake bug in the dictation bar (macOS 26.5.2, Jul 2026). Workaround: restart VoiceInk | No | [#813](https://github.com/Beingpax/VoiceInk/issues/813) |
| Ghost Pepper (dictation) | Hotkey plus AVAudioEngine | Fix plan: observe `didWakeNotification` plus audio config changes, wait 1–2 s, rebuild the engine | No | [#87](https://github.com/matthartman/ghost-pepper/issues/87) |
| OpenWhispr / Wispr Flow / Superwhisper | Globe/Fn hotkeys | Docs say "quit and relaunch" if the hotkey fails; Wispr notes that Secure Keyboard Entry blocks key shortcuts but not modifier-only holds. No wake-specific code found | — | [OpenWhispr hotkeys](https://openwhispr-openwhispr.mintlify.app/configuration/hotkeys), [Wispr docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts) |
| winman | CGEventTap | Wake → 1.5 s delay → tear down, `CFMachPortInvalidate`, recreate | No | §1a |
| OpenLogi | HID tap thread | Probes every 500 ms (`AXIsProcessTrusted`, `CGEventTapIsEnabled`, a throwaway `CGEventTapCreate`). A watchdog **force-exits** the process and launchd restarts it | Yes: watchdog plus launchd restart | [PR #1282](https://github.com/AprilNEA/OpenLogi/pull/1282) |

**Takeaways:**

- The 2024–2026 consensus is to observe wake/unlock, wait 1–2 s, tear down with `CFMachPortInvalidate`, rebuild taps and sessions, and add a periodic health check.
- Self-restart by a watchdog is accepted practice when a supervisor relaunches the app (OpenLogi with launchd; Karabiner's daemons).
- In consumer dictation apps, "relaunch the app" is the support answer today. That is evidence that the industry has no root cause either.

## 3. Staleness of `runningApplications` and `CGWindowListCopyWindowInfo`

- **`NSWorkspace.runningApplications`** only changes while the main run loop runs in a common mode. KVO is the recommended way to observe it ([Apple doc](https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications); the requirement is quoted in [bigduu/Nova #44](https://github.com/bigduu/Nova/issues/44), which hit stale lists without an AppKit main run loop). Hijack runs `NSApplication`'s main run loop, so this should not apply. The local evidence also refutes it: WeType's pid 912 predates the failing process.
- **`CGWindowListCopyWindowInfo`**: no source shows the *public API* going stale inside a long-lived process. [trycua/cua #4038](https://github.com/trycua/cua/issues/4038) (macOS 26.6.2) was the daemon's own cache; the API itself returned correct results. Some windows of long-running UIElement processes lack `kCGWindowOwnerName`, but `kCGWindowOwnerPID` is always present ([lahfir/agent-desktop #211](https://github.com/lahfir/agent-desktop/issues/211)). Hijack matches on pid, which is the robust choice.
- **Unverified** but still possible in-process: the per-process TIS cache (`source(id)` → bundle ID) returning `nil`. Then `isBusy()` returns `nil` and the result looks identical to "no window". The current logs cannot tell the two apart.

## 4. Recommended approach for Hijack

### 4.1 Make the next failure attributable (do this first; it is cheap)

1. **Timestamps:** use an ISO date and time in `log()`. Add the process uptime and a count of wakes since launch to each `down:` line.
2. **Tri-state detection log:** log `isBusy()` as `noBundle`, `noPid`, `pid=[…] windows=0`, or `pid=[…] windows=N (layer, bounds)`. Log it once per session, at the first poll after the forward, and at restore.
3. **Echo probe (posting side):**
   - `handle()` already sees events tagged with `marker`. Log the first Fn `flagsChanged` echo seen after `startVoice()`. If it never arrives, the post never entered the HID stream.
   - Right after posting Fn down, also log `CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)` and `.hidSystemState`.
4. **Recording probe (independent of window detection):** read `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device from about 300 ms to 1 s after the forward. If the mic is running and no window was seen, detection is broken. If the mic is off and the echo was seen, WeType ignored the key. If the mic is off and there was no echo, posting failed.
5. **Environment at each `down:`:**
   - `CGEvent.tapIsEnabled(tap:)`, `AXIsProcessTrusted()`, `CGPreflightPostEventAccess()`, `CGPreflightListenEventAccess()`.
   - `IsSecureEventInputEnabled()`, plus the secure-input pid via `ioreg` when it is on.
   - The front app.
6. **Lifecycle lines:** log `NSWorkspace` `willSleep`, `didWake`, `screensDidSleep`, `screensDidWake`, `sessionDidResignActive`, `sessionDidBecomeActive`, and the distributed notifications `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`. This makes the sleep correlation checkable from the log alone.

### 4.2 What to recreate on wake, unlock, or session activation (debounce, then about 1.5 s delay)

1. Recreate the tap: `tapEnable(false)`, remove the run-loop source, `CFMachPortInvalidate`, then `start()` again. This follows winman and avoids the leak in §1c.
2. Recreate the posting source:
   - Hold one `CGEventSource(stateID: .hidSystemState)` instead of passing `nil`.
   - Rebuild it on wake.
   - Post a defensive Fn-up (`flags = []`) to clear stuck modifier state (§1f).
   - Whether `.hidSystemState` is better than `nil` here is unverified. A/B it using the probes in §4.1.
3. Reset Engine session state: `physicalDown`, `active`, `forwarded`, `passthrough`, `swallowUp`, and bump `generation`. This is the Handy lesson: state can desync if the tap missed a key-up while it was disabled.
4. Re-resolve providers: the TIS source, bundle ID, and pids. Detection should not depend on anything cached.
5. Add a 30 s health timer: `tapIsEnabled` plus `AXIsProcessTrusted`. Recreate the tap if either fails (the eshlox pattern).

### 4.3 Last-resort self-relaunch

Same binary plus a fresh process is the only fix verified so far. So a guarded relaunch is reasonable:

- **Condition:** after recreation, K consecutive genuine sessions (held at least 0.5 s) show no echo, or show echo but no mic and no window, while a new process would behave differently.
- **Action:** `open -n -g /Applications/Hijack.app`, then exit. A small launchd `KeepAlive` agent is the alternative.

This has precedent in OpenLogi and Karabiner's launchd daemons. Log the reason and rate-limit it to at most once every 10 min.

### 4.4 Verification

- **Sleep:** run `pmset sleepnow`, wake the machine, wait 5 s, then do a real hold in TextEdit. Run `sudo pmset relative wake 60` before `sleepnow` to make it unattended.
- **Display and lock:**
  - `pmset displaysleepnow`, then unlock with the password. This also exercises Secure Input.
  - Lock with ctrl+cmd+Q.
  - Fast user switching via the Control Center user menu. Whether the `CGSession -suspend` path still exists on macOS 26 is unverified.
- **Deep idle and DarkWake:** this is what actually happened, and it cannot be forced on demand. Run an overnight clamshell soak and check the new log fields the next morning before relaunching.
- **Pass criteria:** across N=10 holds after each scenario, the log shows the Fn echo, the mic running, and `voice window gone` every time. In a deliberately broken build (skip recreation), the probes must show *which* stage failed. This is the mutation check for the diagnostics.
- Add a `hijack doctor --probe` CLI that runs the echo and flagsState checks without starting a voice session, so an agent can check health after wake.

## 5. Gaps / unverified

- **Root cause unknown.** No public source shows a CGEventPost-posted Fn becoming ineffective, or `CGWindowListCopyWindowInfo` going stale, *only in a long-lived process* while a fresh process on the same machine works. The sleep correlation is unconfirmed locally, because the failing process had no valid attempt before its first sleep.
- The claim that `nil` vs `.hidSystemState` sources behave differently across wake is unverified (§1).
- Whether WeType started recording at 14:55 on Oct 3 is unknown. Neither WeType nor Hijack logged it, and the unified log is gone.
- The internals of BetterTouchTool, Raycast, Rectangle, Superwhisper and Wispr Flow for wake recovery were not found (closed source).
- Hammerspoon's #1502/#3294 have no maintainer root cause. They are symptom evidence only.
- App Nap throttling of the 50 ms polling timer is unlikely: the failing restores fired at a precise ~2.5 s, so timers were running. It is not ruled out for the window poll's sampling.
- The `isBusy` returning `nil` path (TIS bundle lookup failing in-process) cannot be distinguished from "no window" with the current logs.

## Sources

- https://github.com/augustobott/winman/pull/17
- https://github.com/Hammerspoon/hammerspoon/issues/3294 · /1798 · /1507 · /1502
- https://github.com/HD838A/remote-mic-app/issues/476
- https://github.com/cjpais/Handy/issues/840
- https://github.com/jedipunkz/UnNatural/issues/25
- https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md
- https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice
- https://developer.apple.com/forums/thread/766200
- https://github.com/feedback-assistant/reports/issues/524
- https://github.com/openai/codex/issues/40235
- https://github.com/teddychan/yahoo-keykey-2/issues/134
- https://community.folivora.ai/t/conditional-activation-group-with-keyboard-input-source-condition-stays-inactive-after-wake-from-sleep-btt-restart-until-a-real-input-source-change-event/47542
- https://developer.apple.com/forums/thread/795461
- https://eshlox.net/capslock-super-key
- https://www.hammerspoon.org/docs/hs.caffeinate.watcher.html
- https://github.com/Beingpax/VoiceInk/issues/813
- https://github.com/matthartman/ghost-pepper/issues/87
- https://github.com/AprilNEA/OpenLogi/pull/1282
- https://openwhispr-openwhispr.mintlify.app/configuration/hotkeys
- https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts
- https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications
- https://github.com/bigduu/Nova/issues/44
- https://github.com/trycua/cua/issues/4038
- https://github.com/lahfir/agent-desktop/issues/211
- https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid
