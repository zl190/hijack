# Hijack homepage

English-language, dependency-free static homepage. Serve this directory as the website root.

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory site
```

Open http://127.0.0.1:4173 from the repository root. Opening `site/index.html` directly also works; clipboard access depends on browser permissions, with manual selection as the fallback.

The three stories are borrowed voice input (available now), contextual translation (concept), and image-to-notes OCR (concept). The latter two are clearly labeled as not available, not promised integrations. The hero offers three complete, switchable stories: WeType voice, translation, and text capture. Each selection changes the headline, story copy, action, demonstration, and availability. WeType is the first concrete hero story; the product-level idea remains “Your tools. Your rules.” The interactive demonstration uses sample text and timers. It does not record audio or call the native app. The installation action copies the existing local build command, `./install.sh`; there is no binary download or live release endpoint in this checkout.

Assets reuse the approved Hijack icons from the repository's `assets/` directory. Keep these site copies synchronized if the product icon changes. No external fonts, tracking, network APIs, package installs, or build step are required.

At widths up to 900px, the page uses a compact reading path: one selected hero story and demo, a short product statement, and expandable installation instructions. The repeated desktop sections are omitted at this breakpoint.
