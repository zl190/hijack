# 0024. Follow mode: the voice tool starts itself, Hijack only switches back

- Topic: Voice tool integration
- Status: Accepted
- Date: 2026-10-19
- Evidence: docs/incidents/2026-10-04-echo-missing.md, sections 2026-10-19 ("Field tests after the W10 install") and
  the owner's test at about 17:10 below; `~/Library/Logs/Hijack.log` 2026-10-19 16:28 to 16:51; ADR 0023

## Context

Since WeType 3.0.0 (2026-10-17) the Fn that Hijack posts never starts WeType's voice input. ADR 0023 found the
mechanism: WeType's exclusive-mode key listener sits ahead of ours and takes the posted key. The field tests of
2026-10-19 closed every way to post a key that WeType would act on:

| Test | Line | Reading |
|---|---|---|
| Hijack posts without its user-data tag | 16:51:27 `echo missing, ahead: WeType, mic tool off` | the tag is not what WeType judges by |
| WeType's Accessibility permission revoked (its listener gone) | 16:47:05 `echo after 255ms, ahead: none, mic tool off, window while held: 1 window` | the echo is back, but WeType refuses Fn voice without Accessibility (the one window was its permission panel) |
| Post through Karabiner's virtual keyboard | not run | its daemon socket is root-only; an own DriverKit HID device needs an Apple entitlement a self-signed app cannot get |

One more owner test settled the shape of the fix: with WeType's「快捷键全局生效」on, a physical Fn in another input
method (Squirrel) makes WeType switch itself in and listen; after the release the input source stays WeType. So WeType
3.0 now does the front half of Hijack's job itself (switch in, start listening) and rejects any key we post. What is
left undone is the back half of ADR 0003: switch back to the previous input source once the text has landed.

## Decision

A third trigger mode, `follow` (`"triggerMode": "follow"`, `hijack set mode follow`, next to Hold and Toggle in the
menu and in Settings). In it:

1. **The trigger is the tool's own talk key** (Fn for WeType, read as ADR 0004 reads it). The configured shortcut is
   ignored; `hijack status` says so. A user who wants a different physical key maps it in a keyboard remapper
   (Karabiner `right_option → fn`: its virtual keyboard output counts as physical for WeType).
2. **Hijack never posts a key during a dictation.** (The one release of a talk key found stuck at startup, FM-10,
   is unchanged: it is not part of a dictation.) On the press, when the current input source is not the voice source, the key passes
   through untouched, the current source is remembered as the one to switch back to, and a dictation record opens.
   No switch, no post, no event-source rebuild. The mic and window samples while held still run, off the main thread.
3. **On the release the key passes through and the window watch of ADR 0003 starts** (`waitingForText`); when the
   voice window has gone, or the wait runs out, the previous source is restored through the existing `switchTo`
   path, and only if the current source is now the voice source. If the tool never took the key the source never
   changed, and the line says `input source stayed, nothing to switch back`.
4. **Already in the voice source at the press, with no restore pending: passthrough**, exactly as today's same-key
   hold mode. Nothing to restore, no line. A press while a restore is pending (the user presses again before the
   previous text landed) chains: the previous dictation is written up as interrupted and the new one keeps the
   remembered source (the FM-17 rule). A press released before the hold delay (a tap or a chord on the talk key, such
   as Fn+Delete or the Globe key) is written up as `released before fn was held for 0.20s` and left unjudged by
   `hijack stats`, as a too-short hold-mode press is. Unlike hold mode, nothing of ours was switched in, so such a
   press restores nothing unless a voice window was seen or a restore from the previous dictation is pending: a
   Globe-key tap that switched the input source (macOS "Change Input Source") is the user's own switch and is left
   alone (`input source left alone`).
5. **The summary line keeps its shape with the mode word `(follow)`** and no `sent after`, `echo`, `ahead:` or `nap:`
   fields: all four are about a posted key, and none was.
   `dictation com.tencent.inputmethod.wetype.pinyin (follow): held 2.93s, window closed 1627ms after release, back after 1.82s | mic tool on device on, window while held: 1 window | front=…`
   `hijack stats` counts such a line as a dictation (not a too-short tap) and never files a failed one under
   `talk key never went out` or `talk key taken by another app's key listener`. The relaunch of ADR 0022 never fires.
6. **Toggle wins over follow** in the machine (a toggle session needs the posted key); follow with an app provider
   (its own hotkey, no input source) is passthrough: nothing to restore.

In `Sources/Core/SessionMachine.swift` this is one new state, `following`, one mode flag, `follow`, and one effect,
`rememberSource`. `docs/state-machine.md` lines 13 to 15 are its acceptance; `docs/diagrams/states.mmd` carries the
new profile 跟随.

## Field result on the first install, and the second half of the design (2026-10-19 evening)

Two owner dictations on the installed build (609ecdd, follow mode, WeType's「快捷键全局生效」on) worked as voice and
never switched back. The artifacts:

1. `18:36:23 dictation … (follow): held 2.40s, window never closed after release, input source stayed, nothing to switch back | mic tool off device off, window while held: no window (pid 94224)`:
   Hijack saw the key; at the check after the release the source was still Squirrel, and WeType switched itself in
   only later (a TIS read at 18:40:40 said WeType). The press had decided too early, with one read.
2. About 19:50: no dictation line at all. A 50 ms poll of the selected input source (run by the coordinating session)
   shows `19:49:09 im.rime.inputmethod.Squirrel.Hans`, then `19:50:29.896 com.tencent.inputmethod.wetype.pinyin` with
   four `TISNotifySelectedKeyboardInputSourceChanged` posts within 30 ms, while `hijack log --live` captured nothing
   for that press. WeType 3.0's filtering tap, ahead of ours (ADR 0023), swallows the PHYSICAL Fn too when it acts on
   it. The premise of the key path ("let the talk key through, remember the source at the press") does not hold for
   WeType 3.0; the one signal Hijack reliably gets is the input-source change itself.

So the mode has a second entry, and it is the main one for WeType 3.0:

7. **The tool's own switch-in starts the dictation.** The app forwards TIS's selected-input-source notification to
   the engine on the main queue (never from the tap callback). The engine keeps `lastOtherSource`, the most recent
   current source that is not the voice source (seeded at start). In follow mode a change INTO the voice source is
   `toolStarted` (we never select the voice source in that mode, so it is never ours): a dictation begins with no
   key seen, goes back to `lastOtherSource`, and is watched on the tool's signals. A burst of notifications for one
   switch starts one dictation. Hold and toggle mode ignore the event (they select the voice source themselves) and
   still track the other sources.
8. **The tool's window, else its microphone, ends the watch** (`watchTool`, used for the key path's release too in
   follow mode). The voice window, when the tool shows one, says when the text is in (ADR 0003, `capsuleGrace`
   after it closes). When no window is seen, the tool's own microphone (CoreAudio, per process) keeps the dictation
   live, and `micGrace` (1 s, field value pending) after it goes off is the end. A window seen once takes over from
   the mic. Nothing live within `fallbackDelay` from the start is a manual switch to the voice source (⌃Space to type
   with it): left alone, no restore, not judged. A live reading that never ends (another app holding the mic, a
   window that never closes) gives up at `maxToolDictation` (60 s) and still switches back; the line says so.
   Probes run off the main thread, every 0.1 s.
9. **A key path that the tool overtakes.** A switch-in while the key-path record waits for its text (the 18:36 shape)
   writes that record up as `the tool switched itself in, followed from here` (counted as interrupted) and restarts
   the watch on the tool's signals, keeping the source remembered at the press. A switch-in after that record ended
   starts a new dictation that goes back to the tracked source. A press inside the voice source with a tracked
   source (a missed restore left the user there) is a dictation that goes back to it, not passthrough.

The line for the tool path keeps the shape with `switched in by the tool` where `held` was:
`dictation com.tencent.inputmethod.wetype.pinyin (follow): switched in by the tool, mic off 3200ms after start, back after 4.21s | mic tool on device on, window seen: no window (pid 94224) | front=…`
`hijack stats` reads `held` as 0 for it, `mic off … after start` as the text having arrived, `left alone` as not a
dictation.

## Why not

- **Keep posting and fight for the first place in the tap chain.** ADR 0023's "why not": WeType re-creates its
  listener a few seconds after ours appears, and the key would still be judged by WeType.
- **A key that looks physical** (Karabiner's virtual keyboard, Option B of the ledger): closed by the evidence above
  (root-only socket, entitlement). The remapper still has a place: as the user's own `right_option → fn` rule.
- **Only the key.** The first design (items 1 to 6) watched the key alone; the field showed WeType 3.0 swallows the
  physical key when it acts on it (item 7's artifacts). The notification was the way out, with the tool's microphone
  and `fallbackDelay` telling a dictation from the user's own switch to the voice source.
- **A poll of the selected source instead of the notification.** The notification arrives within milliseconds and
  costs nothing between switches; a poll would read TIS on a timer for the life of the process.

## Consequences

- Expected with WeType 3.0: WeType starts on the physical key, Hijack switches back after the text. The field line
  that shows it is the open check below; until it is in, this is the design, not a measurement.
- The front half is WeType's now: whether it listened is visible on the line (`mic tool`, `window while held`) but no
  longer Hijack's to fix. `hijack doctor`'s key-listener warning is reported as harmless in follow mode.
- The `starting` and `listening` states, the hold delay and the switch-in path are untouched and still serve the
  other tools and WeType 2.x.
- A manual switch to the voice source for typing is bounced back only if the tool reads live (window or mic) within
  `fallbackDelay`; a manual switch followed by voice is treated as a dictation and switched back after it. Follow
  mode is for a voice tool used for voice only.
- `micGrace` and the per-process mic reading for WeType are field values still to confirm: the first tool-path lines
  on the installed build will say `mic off … after start` or `nothing live` (then the window or mic probe does not
  see WeType's voice, and the line's `mic tool` / `window seen` fields show which).
- Field check still open at the time of writing: one dictation on the installed build in follow mode that shows
  `switched in by the tool, … back after …` and the input source back to the previous one.

## Verification

`swift test`: 270 tests, 0 failures (236 before W11). `scripts/mutate-w11.sh` breaks one line of shipped code at a
time; the named tests must go RED, then GREEN once the line is restored, and a mutant that does not compile is a FAIL.
Output of the run on 2026-10-19:

```
PASS a follow press starts a posted dictation: broken -> tests RED
PASS a follow press starts a posted dictation: restored -> tests GREEN
PASS a2 following release finishes without the window watch: broken -> tests RED
PASS a2 following release finishes without the window watch: restored -> tests GREEN
PASS a3 following is not active: broken -> tests RED
PASS a3 following is not active: restored -> tests GREEN
PASS a4 the tool's switch-in starts a dictation in every mode: broken -> tests RED
PASS a4 the tool's switch-in starts a dictation in every mode: restored -> tests GREEN
PASS a5 a late switch-in while waiting is ignored: broken -> tests RED
PASS a5 a late switch-in while waiting is ignored: restored -> tests GREEN
PASS b follow mode is never handed to the machine: broken -> tests RED
PASS b follow mode is never handed to the machine: restored -> tests GREEN
PASS b2 a press inside the voice source is passthrough even with a restore pending: broken -> tests RED
PASS b2 a press inside the voice source is passthrough even with a restore pending: restored -> tests GREEN
PASS b3 the source read at the press is never remembered (the tracked one masks it): broken -> tests RED
PASS b3 the source read at the press is never remembered (the tracked one masks it): restored -> tests GREEN
PASS b4 repeats while following are swallowed: broken -> tests RED
PASS b4 repeats while following are swallowed: restored -> tests GREEN
PASS b5 toggle no longer wins over follow: broken -> tests RED
PASS b5 toggle no longer wins over follow: restored -> tests GREEN
PASS b6 the release time is not recorded for a follow dictation: broken -> tests RED
PASS b6 the release time is not recorded for a follow dictation: restored -> tests GREEN
PASS b7 a stale remembered source survives a passthrough release: broken -> tests RED
PASS b7 a stale remembered source survives a passthrough release: restored -> tests GREEN
PASS b8 the source is read at every press: broken -> tests RED
PASS b8 the source is read at every press: restored -> tests GREEN
PASS b9 a too-short follow press is judged like a dictation: broken -> tests RED
PASS b9 a too-short follow press is judged like a dictation: restored -> tests GREEN
PASS b10 a too-short follow press undoes the user's own source switch: broken -> tests RED
PASS b10 a too-short follow press undoes the user's own source switch: restored -> tests GREEN
PASS b11 a chained too-short press drops the pending restore: broken -> tests RED
PASS b11 a chained too-short press drops the pending restore: restored -> tests GREEN
PASS b12 the switch-in notification starts a dictation in hold mode too: broken -> tests RED
PASS b12 the switch-in notification starts a dictation in hold mode too: restored -> tests GREEN
PASS b13 a burst of notifications starts a dictation each: broken -> tests RED
PASS b13 a burst of notifications starts a dictation each: restored -> tests GREEN
PASS b14 the other sources are not tracked: broken -> tests RED
PASS b14 the other sources are not tracked: restored -> tests GREEN
PASS b15 the tracked source is never used as the one to go back to: broken -> tests RED
PASS b15 the tracked source is never used as the one to go back to: restored -> tests GREEN
PASS b16 a switch-in with nothing live still switches back: broken -> tests RED
PASS b16 a switch-in with nothing live still switches back: restored -> tests GREEN
PASS b17 the mic does not keep the dictation live: broken -> tests RED
PASS b17 the mic does not keep the dictation live: restored -> tests GREEN
PASS b18 a window seen does not take over from the mic: broken -> tests RED
PASS b18 a window seen does not take over from the mic: restored -> tests GREEN
PASS b19 the watch never gives up: broken -> tests RED
PASS b19 the watch never gives up: restored -> tests GREEN
PASS c no mic or window sample while following: broken -> tests RED
PASS c no mic or window sample while following: restored -> tests GREEN
PASS c2 the key-listener chain is read for a key that was never posted: broken -> tests RED
PASS c2 the key-listener chain is read for a key that was never posted: restored -> tests GREEN
PASS d the summary line calls a follow dictation hold: broken -> tests RED
PASS d the summary line calls a follow dictation hold: restored -> tests GREEN
PASS d2 a source that stayed is reported as changed by hand: broken -> tests RED
PASS d2 a source that stayed is reported as changed by hand: restored -> tests GREEN
PASS e stats does not read a follow line: broken -> tests RED
PASS e stats does not read a follow line: restored -> tests GREEN
PASS e3 stats reads the mode word anywhere on the line: broken -> tests RED
PASS e3 stats reads the mode word anywhere on the line: restored -> tests GREEN
PASS e2 stats counts a follow line as a too-short tap: broken -> tests RED
PASS e2 stats counts a follow line as a too-short tap: restored -> tests GREEN
PASS static grep: follow reaches Plan, CLI, Config, menu and Settings; the pid lookup is off the tap callback
ALL PASS
```
