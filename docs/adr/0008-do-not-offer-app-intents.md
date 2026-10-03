# 0008. Do not offer App Intents

- Topic: Distribution and signing
- Status: Accepted
- Date: 2026-10-01
- Evidence: 3ddb549, b784b68

## Context

App Intents were added for Shortcuts. Shortcuts listed the actions but could not run them ("Unable to communicate").

## Decision

Remove App Intents. Keep the research in `docs/app-intents-prior-art.md`.

## Consequences

- The likely cause is the missing Team ID. Two public reports describe the same failure with a self-signed app.
- The CLI (`hijack set`, `hijack status`) covers scripts and agents instead.
