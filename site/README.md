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
