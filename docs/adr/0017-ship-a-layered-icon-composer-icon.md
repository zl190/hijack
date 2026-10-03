# 0017. Ship a layered Icon Composer icon

- Status: Accepted
- Date: 2026-10-01
- Evidence: a4d5f1c, c6068f7

## Context

macOS 26 shows icons in Default, Dark, Clear and Tinted appearances. A flat icon does not adapt.

## Decision

Keep `assets/Hijack.icon` (Icon Composer) and compile it with `actool` in `build.sh`. Without Xcode, build a flat icon from the PNG.

## Consequences

- Clear and Tinted come from the system.
- A build with only the Command Line Tools gets the flat icon.
