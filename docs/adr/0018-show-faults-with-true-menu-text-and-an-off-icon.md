# 0018. Show faults with true menu text and an Off icon

- Topic: Faults and reliability
- Status: Accepted
- Date: 2026-10-03
- Evidence: 7161a0e, docs/hci-review-faults.md §5a

## Context

Most faults are silent. The menu and the CLI can say that the shortcut works when it does not.

## Decision

A surface that says something false must change. The menu line and `hijack status` / `doctor` must tell the truth. The icon gets an "Off" state. Show Secure Input in the menu and in the status. Do not send notifications. Do not show a cause table now; look again after seven days of `hijack stats` on 1.1.4.

## Consequences

- The user finds a fault at the next press, and the menu names the step.
- No change on each talk-key edge, so no main-thread cost (FM-26).
