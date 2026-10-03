# 0001. Catch the shortcut with an event tap at the HID level

- Status: Accepted
- Date: 2026-10-01
- Evidence: c6c10c5, cec5eea

## Context

Hijack must see the shortcut before the voice IME and the front app see it. The voice IME also has its own event tap. Hijack posts the talk key itself, and it must not catch its own key.

## Decision

Use one `CGEventTap` at `.cghidEventTap` with `.headInsertEventTap` and `.defaultTap`. Mark every posted event with `eventSourceUserData = 0x5357424B`. Pass marked events through unchanged.

## Consequences

- Hijack is first in the tap chain, so it can swallow the shortcut.
- The tap needs Accessibility permission.
- The callback runs on the main thread. Slow work there makes macOS disable the tap (see 0011).
