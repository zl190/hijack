# Hijack homepage

Dependency-free static pages. Serve `site/` as the website root:

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory site
```

## Routes and ownership

`precise.html` is the single focused homepage template. `?lang=zh` and `?lang=en` select only language; Chinese is the default. The former `precise-zh.html` address redirects to `precise.html?lang=zh`, preserving the fragment. The language link and brand link keep the current route explicit.

`locales.js` owns localized text, accessible labels, metadata, demo messages, and cover-image references. `data-i18n` marks text and `data-i18n-*` marks translated attributes. `precise.js` applies the dictionary and runs one shared phase sequence. Both languages use the same markup, components, styles, and controls. New copy needs matching keys in both dictionaries; structural edits happen only in `precise.html`.

`index.html` remains the earlier broader capability concept page: voice input is available; translation and OCR are explicitly concepts. It uses `styles.css` and `script.js`. No packages, build step, external fonts, analytics, or runtime network APIs are required.

## Demonstration contract

The shared demo runs typing → voice input → restored input source. The illustration skips the waiting interval; the native app still waits for text submission before restoring the previous source. WeType is the voice example, and Rime/Squirrel is the illustrative previous input source. The page never records audio, calls the native app, or executes an installer.

Only the central Hijack button starts playback. Its visible label is 播放演示 / Play demo. The two circles are passive state indicators, avoiding the suggestion that the microphone starts recording. Faint paired arcs show the round trip while idle. Playback highlights only the active direction; the return cue clears after 950ms. Hijack hops 22px sideways and 12px upward in the corresponding direction. The cover and editor share a fixed aspect ratio. A return chevron becomes available after completion, visible on hover, keyboard focus, or touch layouts. Returning moves focus to the replay button.

Playback uses one cancellable timer. Restarting, returning to the cover, and restoring a page from the browser back/forward cache reset pending work. Motion respects `prefers-reduced-motion`; state transitions still work with animation disabled.

## Installation and compatibility

Both languages show the same curl and Homebrew commands. Installation requires Apple silicon and macOS 13+. The command disclosure defaults open on desktop and closed on compact screens; direct installation navigation opens it. Resizing preserves the user's disclosure choice. Clipboard failure selects the command for manual copying.

The support list reflects the project owner's report on 2026-10-01: WeType, Sogou IME, Doubao IME, and Handy were tested; Wispr Flow, Openless, and Typeless are supported with testing pending. Input methods and standalone apps form separate columns. Checkmarks identify the tested entries. These are owner-provided facts, not native integration tests performed while building the homepage.

## Assets and cache

Hijack icons are copies of the approved repository artwork. The current Chinese source indicator is an inline monochrome Rime symbol extracted from the installed Squirrel app's `rime.pdf`, with the background excluded. The retained `assets/squirrel.png` comes from its `Rime.icns`. Upstream: https://github.com/rime/squirrel.

`assets/hijack-want-it-all-face.png` is the approved cover. It was edited with the built-in image-generation tool from the movie still at https://tools.wingzero.tw/memes/26 (image: https://i.imgur.com/Ak4RdhN.png). The header reads 语音输入 + 鼠须管; a small tilted Hijack label sits on the central face. The underlying movie imagery is not original MIT-licensed project artwork. The earlier cover remains in `assets/hijack-want-it-all.png`.

HTML references use `?v=` followed by the first 12 hexadecimal characters of each CSS/JS file's SHA-256. After modifying a referenced file, update its fingerprint in every referring HTML page. This prevents a cached script from running against incompatible markup without introducing a build pipeline.

See `docs/homepage.md` for the current review and validation record. Earlier design iterations are preserved in Git history.

English image localization: `assets/hijack-why-not-both-en.png`, made with the built-in image tool from the approved Chinese cover. Prompt: preserve all framing, people, expressions, colors, and the small tilted Hijack face label; replace only the top title with “Voice input + Rime” and the bottom subtitle with “Why not both?”. This is a localized asset in the same template, not a separate page design.
