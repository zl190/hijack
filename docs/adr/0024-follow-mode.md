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
   `hijack stats`, as a too-short hold-mode press is; the window watch and the restore still run, as they do there.
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

## Why not

- **Keep posting and fight for the first place in the tap chain.** ADR 0023's "why not": WeType re-creates its
  listener a few seconds after ours appears, and the key would still be judged by WeType.
- **A key that looks physical** (Karabiner's virtual keyboard, Option B of the ledger): closed by the evidence above
  (root-only socket, entitlement). The remapper still has a place: as the user's own `right_option → fn` rule.
- **Switch back from a watcher on the input source instead of a key.** It would need a poll or a TIS notification
  and could not tell a dictation from the user's own switch to WeType. The key edges we already see give the boundaries
  for free, and the mode reuses the existing window watch unchanged.

## Consequences

- Expected with WeType 3.0: WeType starts on the physical key, Hijack switches back after the text. The field line
  that shows it is the open check below; until it is in, this is the design, not a measurement.
- The front half is WeType's now: whether it listened is visible on the line (`mic tool`, `window while held`) but no
  longer Hijack's to fix. `hijack doctor`'s key-listener warning is reported as harmless in follow mode.
- The `starting` and `listening` states, the hold delay and the switch-in path are untouched and still serve the
  other tools and WeType 2.x.
- Field check still open at the time of writing: one dictation on the installed build in follow mode (see the
  incident doc for its line once it is in).

## Verification

`swift test`: 257 tests, 0 failures (236 before W11). `scripts/mutate-w11.sh` breaks one line of shipped code at a
time; the named tests must go RED, then GREEN once the line is restored, and a mutant that does not compile is a FAIL.
Output of the run on 2026-10-19:

```
PASS a follow press starts a posted dictation: broken -> tests RED
PASS a follow press starts a posted dictation: restored -> tests GREEN
PASS a2 following release finishes without the window watch: broken -> tests RED
PASS a2 following release finishes without the window watch: restored -> tests GREEN
PASS a3 following is not active: broken -> tests RED
PASS a3 following is not active: restored -> tests GREEN
PASS b follow mode is never handed to the machine: broken -> tests RED
PASS b follow mode is never handed to the machine: restored -> tests GREEN
PASS b2 a press inside the voice source is passthrough even with a restore pending: broken -> tests RED
PASS b2 a press inside the voice source is passthrough even with a restore pending: restored -> tests GREEN
PASS b3 the previous source is never remembered: broken -> tests RED
PASS b3 the previous source is never remembered: restored -> tests GREEN
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
PASS e2 stats counts a follow line as a too-short tap: broken -> tests RED
PASS e2 stats counts a follow line as a too-short tap: restored -> tests GREEN
PASS static grep: follow reaches Plan, CLI, Config, menu and Settings; the pid lookup is off the tap callback
ALL PASS
```
