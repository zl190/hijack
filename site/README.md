# Hijack homepage

English-language, dependency-free static homepage. Serve this directory as the website root.

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory site
```

Open http://127.0.0.1:4173 from the repository root. Opening `site/index.html` directly also works; clipboard access depends on browser permissions, with manual selection as the fallback.

The three stories are borrowed voice input (available now), contextual translation (concept), and image-to-notes OCR (concept). The latter two are clearly labeled as not available, not promised integrations. The hero offers three complete, switchable stories: WeType voice, translation, and text capture. Each selection changes the headline, story copy, action, demonstration, and availability. Available/Concept badges appear directly on the story selectors. WeType is the first concrete hero story; the product-level idea remains “Your tools. Your rules.” The interactive demonstration uses sample text and timers. It does not record audio or call the native app. The install section provides the published curl installer and Homebrew cask commands, with independent copy actions. Installation requires Apple silicon, macOS 13+, and a configured WeType voice key. It downloads a prebuilt release; no source checkout or developer tools are required. The page does not execute either installer.

Assets reuse the approved Hijack icons from the repository's `assets/` directory. Keep these site copies synchronized if the product icon changes. No external fonts, tracking, network APIs, package installs, or build step are required.

At widths up to 900px, the page uses a compact reading path: one selected hero story and demo, a short product statement, an expandable workflow explanation, and expandable installation instructions. The repeated desktop sections are omitted at this breakpoint.

## Focused alternative

[`precise.html`](precise.html) is a separate English homepage covering only the shipping WeType voice workflow. It uses `precise.css` and `precise.js` and shares the existing icon assets. The broader concept homepage remains unchanged at `index.html`.

Its demonstration makes the macOS input source explicit: ABC → WeType while holding → WeType while finishing after release → ABC after text submission. ABC is illustrative; Hijack restores the previous source. Serve this directory and open `/precise.html` to compare versions.

[`precise-zh.html`](precise-zh.html) is the Simplified Chinese version of the focused homepage. Its header links to English, and the English header links back to Chinese. Both pages share `precise.css` and `precise.js`; the document language selects demo and clipboard messages. Installation commands are identical in both languages.

The Chinese page uses `assets/hijack-want-it-all-face.png` as the initial demo cover. Click either circular input-source control to start the demonstration; the cover has no play overlay. This user-requested meme adaptation was created with the built-in image-generation tool from the movie still linked at https://tools.wingzero.tw/memes/26 (image: https://i.imgur.com/Ak4RdhN.png). The movie imagery is not part of the project's original MIT-licensed artwork.

The Chinese switcher uses two circular controls with curved directional arrows around the Hijack icon. Both arrows and Hijack animate once per hand-off. Its compact sequence goes directly from voice input to the restored source; the native app still waits for text submission before restoring the previous input method. The completed demo reveals an SVG return chevron on hover or keyboard focus (always visible on touch devices). `assets/squirrel.png` is extracted from the installed official Squirrel app’s `Rime.icns`, representing the third-party Rime/Squirrel project (https://github.com/rime/squirrel).

The central Hijack icon is also a replay button, with a separate hover/focus spring and pressed feedback. The extra demonstration heading is omitted. The face-label cover was edited with the built-in image-generation tool. Prompt: move the bottom-right Hijack wordmark onto the center of the left white-bearded man’s face as smaller, tilted, casual lettering, preserving his expression and the rest of the meme. The prior cover remains available as `assets/hijack-want-it-all.png`.

The current Chinese typing control uses the monochrome Rime symbol, extracted from the installed Squirrel app’s vector `rime.pdf` menu-bar asset, with its background excluded. The inline SVG inherits the control’s text color, matching the microphone treatment. The prior app-tile PNG remains available in assets.

The Chinese support list follows the project owner’s report on 2026-10-01: WeType, Sogou, Doubao IME, and Handy are tested; Wispr Flow, Openless, and Typeless are supported but not yet personally tested. This is owner-provided compatibility evidence, not a test run performed by the homepage agent. The page’s requirement and privacy text now refer to voice tools generally; the demo still uses WeType as its example.
