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

## Release-instructions review correction

Diagnosis: the homepage’s installation copy was based on `cb1ab6a`, which built from source. Main commit `03b1eb4` changed `install.sh` to download a prebuilt release, added `install-from-source.sh`, and documented curl/Homebrew installation. The isolated homepage branch was rebased onto the updated `origin/main` before this correction.

The original installation content audit failed all four checks: missing curl command, missing Homebrew command, incorrect Command Line Tools prerequisite, and incorrect source-checkout prerequisite.

Read-only verification on 2026-10-01:
- Published installer: https://raw.githubusercontent.com/zl190/hijack/main/install.sh
- Homebrew cask: https://raw.githubusercontent.com/zl190/homebrew-tap/main/Casks/hijack.rb
- GitHub release: https://github.com/zl190/hijack/releases/tag/v1.0.0, with `Hijack.zip` (2,027,613 bytes).
- Both installer and cask require Apple silicon; README/cask require macOS 13+.
- Reviewed the complete unchanged `Hijack.swift`: it switches input sources, forwards trigger-key events, observes the voice capsule, and logs event/focus metadata. It has no audio capture, storage, or upload code. WeType’s server-side audio processing and retention were not independently verified, so the FAQ directs users to its privacy policy and does not claim local-only recognition.

Changes: two prebuilt installation commands with independent copy feedback; no developer-tool/source-checkout prerequisites; explicit Available/Concept selector badges; independent-project/non-affiliation footer; compact workflow disclosure on narrow screens; privacy answer scoped specifically to audio. The installer scripts and app were not executed or changed.

Verified in the live preview:
- Both command blocks match the published README exactly; clipboard contents match each command after the asynchronous write completes.
- Installer disclosure, privacy FAQ, and compact workflow explanation expand correctly.
- Available/Concept labels appear in the selectors before any interaction; affiliation disclaimer remains visible on narrow screens.
- 390 px collapsed page height: 1,207 px. At 320 px with installation expanded and at 1440 px desktop width, document scroll width equals viewport width.
- Desktop installation defaults open; compact defaults closed. No console warnings/errors reported.
- `node --check site/script.js`, HTML structure/link checks, and `git diff --check` pass. Install commands were verified read-only and were not executed.

## Focused alternative / precise.html

User request: create another precise version explaining only the current implemented function. Preserve the existing broad homepage.

Contract: inputs are the current Swift behavior, release installation instructions, and existing icon assets. Outputs are `site/precise.html`, `site/precise.css`, and `site/precise.js`; no app, installer, or existing homepage behavior changes. The page contains no speculative translation/OCR features. The sample dictation is timer-driven and never accesses the microphone.

Composition: one explicit proposition → input-source state demonstration → installation commands and privacy. The four visible stages distinguish release from restoration; the input source remains WeType while dictation finishes. Both the headline copy and demonstration state that the previously selected source is restored.

Verification:
- Browser playback: holding shows WeType; release/finishing still shows WeType; submitted text restores ABC and enables replay.
- Both clipboard commands match the published README exactly; installer scripts were not executed.
- Installation and privacy disclosures work.
- No horizontal overflow at 320, 390, or 1440 CSS pixels. Collapsed mobile page height at 390px: 1,202px.
- No browser warnings/errors reported. JavaScript syntax, HTML nesting/IDs/local-link checks, and whitespace checks pass.
- Original `site/index.html`, `site/script.js`, and `site/styles.css` remain unchanged from the prior commit.
- Clipboard denial fallback and disabled-JavaScript browser execution were not exercised; static markup retains the entire four-step explanation and manual-copy commands.

## Simplified Chinese focused homepage

User request: add a Chinese version of the focused homepage. Added `site/precise-zh.html` with translated copy, metadata, accessibility labels, installation guidance, and privacy explanation. Both languages share the demonstration logic and styles, with scoped Chinese typography and reciprocal language links. The installation command strings are unchanged.

Verification: the Chinese demonstration retains WeType after key release while text is being submitted, then restores ABC. Chinese clipboard feedback works. Navigation to English and English playback still work. The Chinese layout has no horizontal overflow at 320 and 390 CSS pixels; at 390px its collapsed document height is 1,206px. HTML structure, IDs, local links, command equality, JavaScript syntax, and whitespace checks pass. No native behavior or deployment is included.

## Chinese copy and meme cover

The Chinese hero now reads “语音输入，自己的输入法，我全都要。” The example source is 鼠须管 (Squirrel for macOS). The workflow has three cards; the last card shows WeType while text is being submitted and then returns to 鼠须管. Repetitive slogans were removed and practical setup/privacy information retained in shorter copy.

The user-selected meme is the initial cover. The final requested button text is “▶ 播放演示”, including replay. The play button overlays the bottom-right corner of the full image. Clicking replaces the cover with the existing editor animation. Verified in-browser: cover and button visible; release stage still shows WeType; completed stage restores 鼠须管; the final button remains available. At 390px the full image and button fit and document width equals viewport width. JavaScript syntax and whitespace checks passed.
