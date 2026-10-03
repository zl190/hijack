# 0003. Switch back after the voice window closes

- Status: Accepted
- Date: 2026-10-01
- Evidence: cb1ab6a

## Context

WeType first shows rough text, then the final text. If Hijack switches away too early, the text is lost or goes to the clipboard.

## Decision

After the release, watch the voice tool's on-screen windows (`CGWindowListCopyWindowInfo` by owner pid). Switch back 0.15 s after the window closes. If a window was seen, wait 5 s at most. If no window was seen, wait 2.5 s.

## Consequences

- The text arrives before the switch in normal use (median 1.6 s after release).
- When the window never shows, the user waits 2.5 s and may lose the text. The summary line records it.
