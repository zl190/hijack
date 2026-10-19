# 0023. Read the key-listener chain before judging a failed post

- Topic: Faults and reliability
- Status: Accepted
- Date: 2026-10-19
- Evidence: docs/incidents/2026-10-04-echo-missing.md, section 2026-10-19; `scripts/taps.swift`; `~/Library/Logs/Hijack.log` 2026-10-17 to 2026-10-19

## Context

Since 2026-10-17 every dictation but one ended in `echo missing`, and the self-relaunch of ADR 0022 stopped helping: the
fresh process failed within seconds. The cause is outside the process. WeType 3.0.0 (installed that day) keeps a filtering
key listener ahead of ours: it watches the tap list for competitors and re-creates its own tap a few seconds after a new
one appears, so it sees every key event, our posted Fn included, before our tap does. Our tap never sees the echo, and
WeType does not start listening. A tap created later runs earlier; a restart of Hijack wins the first place for about
four seconds.

ADR 0022's signature assumed that `echo missing` means the post never left this process. It can also mean the post was
swallowed one step ahead of us. The two need different answers: a relaunch for the first, nothing from our side for the
second (it is a setting in the other app, or a different talk key).

The `post:` probe of W7 never read `seen` on any good dictation (0 of 48): both key states it read reflect the keyboard,
not a posted flagsChanged. It cannot tell the two cases apart either.

## Decision

1. **Read the chain at the sample.** 0.3 s after the talk key went out (the sample that already reads App Nap), read
   `CGGetEventTapList` once and keep the names of the other processes whose enabled, filtering, key-event taps at the HID
   level are listed before ours. The dictation line carries it as `ahead: none`, `ahead: WeType`, `ahead: A+B`, or
   `ahead: ?` (not sampled, or the list could not be read). It replaces `post:`.
2. **No relaunch behind another listener.** The relaunch of ADR 0022 keeps its signature minus the `post:` term (hold
   style, held at least 0.5 s, talk key sent, no echo) and gains one exclusion: when `ahead:` names anyone, log
   `self-relaunch skipped: <names>'s key listener sits ahead of ours (talk key did not go out: echo missing)` and do
   nothing else. A fresh process would be behind it again within seconds. An unread chain (`?`) does not block the
   relaunch: it is still the one remedy for a fault inside the process.
3. **Say it in `doctor` and `stats`.** `hijack doctor` prints `no other key listener sits ahead of Hijack's`, or a warning
   with the names and what to do (turn WeType's voice-input exclusive mode off, or use a talk key other than Fn).
   `hijack stats` prints `Key listener  another app's listener sat ahead of ours during N of M sampled dictations (K of
   those failed)` once any line carries the field, and `--json` gains `aheadSampled`, `listenerAhead`, `listenerAheadFailed`.

The read is one call to the window server, no I/O; it runs on the main thread inside the existing sample, never inside the
tap callback (ADR 0011).

## Why not

- **Re-create our own tap before every post.** It would put us first for the next few seconds and bring the echo back,
  but WeType re-creates its tap again, and the talk key would still be judged by WeType; the two apps would take turns
  rebuilding taps on every dictation. Measuring is cheaper than fighting.
- **Post the talk key through Karabiner's virtual keyboard** (Option B of the private ledger): then the key looks physical
  to everyone. A heavy dependency, kept as the fallback if WeType offers no setting that works.
- **Keep `post:` and fix its read.** No state readable from our process shows a posted flagsChanged; the probe has no
  correct form.

## Consequences

- A failed post now says which of the two faults it was. The owner's next move follows from the line.
- The relaunch count stops rising for a fault it cannot fix; `self-relaunch skipped` lines take its place.
- The heuristic reads list order. For head-inserted taps that is run order (measured); a tail-appended filtering tap
  from a younger process would also be listed before ours while running after. The names tell a reader which case it is.
- ADR 0022 stays in force for the case it was written for. Its `post not seen` term is gone from the signature and the log line.

## Verification

`scripts/mutate-w10.sh` breaks one line of shipped code at a time; the named tests must go RED, then GREEN once the line
is restored. Output of the run on 2026-10-19:

```
PASS a summary always prints ahead: none: broken -> tests RED
PASS a summary always prints ahead: none: restored -> tests GREEN
PASS a2 unreadable chain prints ahead: none: broken -> tests RED
PASS a2 unreadable chain prints ahead: none: restored -> tests GREEN
PASS b chain read on every sample: broken -> tests RED
PASS b chain read on every sample: restored -> tests GREEN
PASS c relaunch guard inverted (skips when ours is first): broken -> tests RED
PASS c relaunch guard inverted (skips when ours is first): restored -> tests GREEN
PASS c2 relaunch guard dropped: broken -> tests RED
PASS c2 relaunch guard dropped: restored -> tests GREEN
PASS c3 unread chain counts as a listener ahead: broken -> tests RED
PASS c3 unread chain counts as a listener ahead: restored -> tests GREEN
PASS d stats ignores the ahead field: broken -> tests RED
PASS d stats ignores the ahead field: restored -> tests GREEN
PASS d2 stats counts a failure as any listener ahead: broken -> tests RED
PASS d2 stats counts a failure as any listener ahead: restored -> tests GREEN
PASS static grep: keyListenersAhead filters hid/enabled/filtering key taps, defined once, used by doctor
ALL PASS
```
