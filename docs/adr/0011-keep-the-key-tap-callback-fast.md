# 0011. Keep the key-tap callback fast

- Status: Accepted
- Date: 2026-10-03
- Evidence: e9b25c5, 7570709

## Context

The tap callback runs on the main thread. macOS disables a tap that is too slow. Taps after Hijack's tap, such as WeType's, also wait.

## Decision

Inside the callback, do no file I/O, no Accessibility query, no input-source switch, no CoreAudio call and no window-list call. Use a settings snapshot (`Plan`). Write the log on a background queue. Sample the mic and the window off the main thread. Look up the voice tool's processes once per dictation.

## Consequences

- Measured with Instruments: Hijack CPU went from 16 ms/s to 4.9 ms/s during a dictation, with no main-thread hangs.
- New code in `handle()` must keep this rule. A review must check it.
