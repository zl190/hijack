# Homepage delivery

## Contract

- Input: product behavior in `Hijack.swift`, requirements and installation in `README.md` / `install.sh`, approved icons in `assets/`.
- Output: an English static homepage in `site/`, ready to serve as a directory.
- Side effects: website files and documentation only. No changes to native behavior, user input sources, permissions, installed applications, deployment, or remote Git state.
- Guarantees: no runtime dependencies or external requests; demonstration is clearly labeled; scenario switching cancels pending demonstration callbacks; repeated demos reset cleanly; copy failures offer manual selection; the core page remains useful without JavaScript.

## Composition and claims

Primary action: understand capability borrowing as a way to compose a personal workflow, explore three parallel capability examples, and reach truthful local installation instructions.

Attention path: autonomy statement → three capability demos → three capability-borrowing stories → general borrowing pattern → preferences → installation.

The three sibling stories describe borrowing capabilities: voice, translation, and OCR. Voice is the working example. Translation and OCR are explicit concepts, not shipped features or commitments. The demo examples do not assert tested integration with specific editors or email clients. The icon's tipping-hat meaning carries into the closing line.

User direction: broaden the story beyond three text-entry tasks; use an English interface. Core proposition: apps provide capabilities, users compose their workflow. WeType is one example of a borrowed capability, not the product’s defining scope. Voice, translation, and text capture sit side by side in the hero; per-example availability distinguishes the current build from concepts.

Reuse decision: adapted the repository's existing icon artwork and product/installation language from commit `cb1ab6a`. Built the thin explanatory page with native HTML/CSS/JS because no frontend stack, package boundary, or existing site is present. No external component framework needed.

## Initial version verification

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

## Capability-first revision

The page now defines Hijack through the general borrowing pattern. WeType is the first full hero story, with its own headline and narrative, alongside translation and text-capture stories. The persistent product-level line is “Your tools. Your rules.” Each selection changes the hero headline, description, primary action, availability label, and demo together. Demo data now owns capability, availability, result, and status strings per example; switching examples cancels the previous run. No native integrations were added.

Revision checks passed in the browser: selecting Translation replaces the full hero and points its primary action to the general borrowing pattern; selecting Text capture during playback cancels the earlier run and retains the correct concept label, context, and idle state. Enter starts the text-capture demo. Layout has no horizontal overflow at 320 and 390 CSS pixels. The installation copy continues to identify the current build as WeType voice only. `node --check` and whitespace checks passed. The earlier native-app and clipboard-failure limitations still apply.

## Compact portrait layout

Diagnosis: at 390 × 844, the previous page was 5,257 CSS pixels tall. The three repeated scenario cards occupied 1,858 pixels, despite all three stories already being available in the hero switcher.

At widths up to 900 pixels, the page now presents the selected hero story and demo, the short product statement, and installation in a native details disclosure. Repeated scenario cards, expanded pattern, and preference summaries are omitted from this compact reading path. The header links directly to the story switcher; hidden desktop actions cannot point users to hidden sections. The existing Settings FAQ remains available inside installation.

Verification:
- 390 px: 1,099 px default document height, compared with 5,257 px before (about 79% shorter).
- 320 px: 1,097 px document height for the translation story; no horizontal overflow.
- Story switching retains the correct headline, availability, and demo.
- Installation expands and collapses; command is visible and copying succeeds.
- 1440 px: full desktop sections remain visible, installation opens by default, no horizontal overflow.
- Narrow/wide transitions update the disclosure default; users can open or close it directly between transitions.

No new native capability, release, or deployment is included in this revision.
