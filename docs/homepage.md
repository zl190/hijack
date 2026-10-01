# Homepage delivery

## Contract

- Input: product behavior in `Hijack.swift`, requirements and installation in `README.md` / `install.sh`, approved icons in `assets/`.
- Output: an English static homepage in `site/`, ready to serve as a directory.
- Side effects: website files and documentation only. No changes to native behavior, user input sources, permissions, installed applications, deployment, or remote Git state.
- Guarantees: no runtime dependencies or external requests; demonstration is clearly labeled; scenario switching cancels pending demonstration callbacks; repeated demos reset cleanly; copy failures offer manual selection; the core page remains useful without JavaScript.

## Composition and claims

Primary action: understand capability borrowing as a way to compose a personal workflow, see the working voice example, and reach truthful local installation instructions.

Attention path: autonomy statement → illustrative input-source round trip → three capability-borrowing stories → current voice mechanism → preferences → installation.

The three sibling stories describe borrowing capabilities: voice, translation, and OCR. Voice is the working example. Translation and OCR are explicit concepts, not shipped features or commitments. The demo examples do not assert tested integration with specific editors or email clients. The icon's tipping-hat meaning carries into the closing line.

User direction: broaden the story beyond three text-entry tasks; use an English interface. Core proposition: apps provide capabilities, users compose their workflow.

Reuse decision: adapted the repository's existing icon artwork and product/installation language from commit `cb1ab6a`. Built the thin explanatory page with native HTML/CSS/JS because no frontend stack, package boundary, or existing site is present. No external component framework needed.

## Verification

Verified in the Codex in-app browser on 2026-10-01 at `http://127.0.0.1:4173`:

- Pass: rendered desktop and mobile layouts; DOM overflow checks at 320, 390, and 1440 CSS pixels returned viewport width equal to document scroll width, with no overflowing elements.
- Pass: demo transitions ABC → WeType → ABC and enables replay after completion.
- Pass: changing from an active Email demo to Notes cancels prior callbacks, leaving Shuangpin and the Notes placeholder intact after the old timer would have completed.
- Pass: Tab from the final example button reaches Play demo; Enter starts the demonstration.
- Pass: Copy command displays success; installation navigation and privacy disclosure open their intended content.
- Pass: all five displayed images loaded; no browser console warnings/errors were reported during the pass.
- Pass: static link/asset resolution, unique IDs, one H1, English-only HTML/JS interface text, both concept disclaimers, `node --check site/script.js`, and `git diff --check`.
- Not exercised: clipboard denial/manual-copy fallback and a browser with JavaScript disabled. The fallback was source-reviewed; static HTML contains the complete core narrative and installation instructions.
- Not applicable: account/session/private-data states; the homepage has no accounts, private content, saved state, or remote writes.

Native behavior in real target applications was not retested; demo text is illustrative and the app itself was not modified.

No native build needed: Swift code and installation scripts are unchanged. No deploy requested. Original checkout stays untouched; the homepage lives on `codex/hijack-homepage` in an isolated Codex-owned worktree.
