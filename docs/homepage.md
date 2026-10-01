# Homepage delivery and review

## Scope and data contract

Inputs: product behavior in `Hijack.swift`, published installation instructions, approved Hijack artwork, and the owner's 2026-10-01 voice-tool support report. Outputs: static pages in `site/` and this documentation. Side effects are limited to those files and a local branch checkpoint; native code, installers, installed apps, deployment, and remote Git state are unchanged.

The single focused page, localized in Chinese and English explain temporary voice-tool use followed by restoration of the previous input source. The broader page retains explicitly labelled translation/OCR concepts. All editor text is illustrative. No page captures audio, runs installation commands, or sends analytics.

## HCI and implementation review — 2026-10-01

Diagnosis: incremental edits had left competing CSS overrides, different English/Chinese phase models, and clickable microphone/source circles that resembled recording controls. The support block repeated category labels, while whole-element fading reduced text legibility. Installation disclosures reset on viewport changes. The broader demo cancelled timers on page exit without recovering its disabled play button after a back/forward-cache restore.

Decisions and resulting behavior:

- One shared playback action: the central Hijack button with a visible 播放演示 label. The circles communicate state and are not interactive.
- One phase model in both focused languages: typing → voice input → restored. The native waiting behavior remains unchanged; the illustration omits the waiting interval.
- Directional arrows appear only when relevant. The return cue clears after 950ms, including with reduced motion; faint paired idle arcs preserve the round-trip idea. Hijack hops 22px sideways and 12px upward. Cover/editor geometry stays stable.
- CSS is organized by component, language, motion, and breakpoint; superseded appended overrides are removed. One cancellable timer controls focused playback and cue cleanup.
- The support list groups input methods and standalone apps into separate columns, with four tested checkmarks and one legend. Text stays readable while the inactive microphone and surface are dimmed.
- Replay, return, navigation, and disclosures support keyboard use. The return target is 44×44px; compact copy targets are at least 44px tall.
- Disclosure defaults are applied once. User choices survive resizing; installation links open the commands.
- Both scripts recover from back/forward-cache restoration. A single focused HTML template and locale dictionary prevent design drift between languages. Content fingerprints keep HTML, CSS, and JavaScript versions aligned.

Accessibility references used for review: [button semantics](https://www.w3.org/WAI/ARIA/apg/patterns/button/), [minimum contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html), and [target size](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html). This is a targeted review, not a full accessibility certification.

## Verification

Browser checks on the current focused pages:

- Chinese layout at 320px and 390px has no horizontal overflow. At 320px, cover and completed editor both measure 162.0859375px tall.
- Keyboard activation starts playback; the source reaches WeType then returns to Squirrel. Returning to the cover restores central-button focus. The return hit target is 44×44px.
- Outbound and return arrows follow the selected phase; the idle cover retains both faint directional arcs.
- The compact support list fits, install navigation expands commands, copying gives Chinese success feedback, and a manually collapsed disclosure remains collapsed after viewport reset.
- English playback completes all three phases and restores Rime. The same central button restarts playback. Language navigation works.

Independent actual-script VM checks pass for both 700ms/1800ms sequences, the 950ms return cue, rapid replay cancellation, cover reset/focus, and persisted pagehide/pageshow recovery in both scripts. Both circles have no interaction handlers. Reduced-motion cue cleanup was reviewed explicitly.

Static checks cover JavaScript syntax, HTML nesting and unique IDs, one H1 per page, local asset/fragment references, command equality, content fingerprints, and whitespace. The homepage is served at `/` from `index.html`; the old precise URLs redirect while preserving language and fragment, and the earlier broad page is retained as `concept.html`; English and Chinese use identical element structure and behavior. Native integration tests were not rerun; the seven-tool support evidence comes from the owner. Clipboard denial and disabled-JavaScript browser execution were not exercised; manual-copy fallback and static content were source-reviewed. The in-app browser did not reproduce an actual back/forward-cache restore, so that lifecycle recovery was validated by the VM harness.

## Installation and privacy evidence

Release instructions were checked read-only against main commit `03b1eb4`, the published installer at https://raw.githubusercontent.com/zl190/hijack/main/install.sh, the Homebrew cask at https://raw.githubusercontent.com/zl190/homebrew-tap/main/Casks/hijack.rb, and release v1.0.0. Installers were not executed. The reviewed Swift source switches input sources and forwards trigger events; it does not capture, store, or upload audio. The selected voice tool's own policy governs speech processing and retention.

The work remains on the isolated `codex/hijack-homepage` branch. No publication or deployment is included. Asset provenance and local serving instructions are maintained in `site/README.md`; superseded design notes remain in Git history.
