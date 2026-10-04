# swift-format

Hijack uses Xcode's bundled `swift-format`, run as `xcrun swift-format`. It is not on `PATH`.

## Commands

- `make lint` checks `Sources` and `Tests` against `.swift-format`. It changes no files and
  exits non-zero on any violation.
- `make fmt` rewrites `Sources` and `Tests` in place to match `.swift-format`. Review the diff
  before committing; do not run it as part of CI.

## Config choices

`.swift-format` was measured from the code as written, so the first full format touches as
little as possible.

| Setting | Value | Why |
|---|---|---|
| `indentation.spaces` | 4 | The code already indents with 4 spaces (the default is 2). |
| `lineLength` | 140 | The 95th-percentile line in `Sources` is 129 characters; 140 covers it with room. |
| `lineBreakBeforeEachArgument` | `false` | Matches the code's style of keeping short argument lists on one line. |
| `respectsExistingLineBreaks` | `true` | Keeps manual line breaks the code already chose, instead of reflowing everything. |
| `maximumBlankLines` | 1 | Matches the code's existing blank-line convention. |

## Rules decision table

| Rule | On/Off | Reason |
|---|---|---|
| `DoNotUseSemicolons` | Off | Fights the code's single-line `if`/case bodies joined with `;`. |
| `OneVariableDeclarationPerLine` | Off | Fights the code's `let a = x, b = y` grouping style. |
| `AlwaysUseLowerCamelCase` | Off | Fights the test suite's `testID_Description` naming. |
| `NeverForceUnwrap` | Off | 77 existing hits; too noisy to flip on without a dedicated pass (see below). |
| `OrderedImports` | On | Catches accidental import reordering; only 6 hits today. |
| `NoAssignmentInExpressions` | On | Catches an assignment used where a condition was meant; a real defect pattern. |
| `UseEarlyExits` | Off | The code often checks and returns deep in a function body; this matches the default and the existing shape. |
| `OneCasePerLine`, `OnlyOneTrailingClosureArgument`, `NoParensAroundConditions` | On (default) | Measured: the code has no multi-case enum lines, no multi-trailing-closure calls, and no redundant condition parens, so these never fire. |
| `TrailingComma`, `GroupNumericLiterals` | On (default) | Not fought by any deliberate pattern; the 9 and 1 remaining hits are small and worth fixing by hand. |

See `.swift-format`'s `## Disabled rules` section above the table for the full one-sentence
reasoning kept as a code comment equivalent (JSON itself cannot hold comments).

## Current lint status

`make lint` exits non-zero with 589 violations across 9 rule categories, all of them downstream
of the codebase's dense one-statement-per-line style (semicolon-joined switches, packed struct
literals, long argument lists), which swift-format reflows onto multiple lines regardless of
rule toggles:

```
 168 AddLines
 157 Spacing
 152 Indentation
  74 LineLength
  20 RemoveLine
   9 TrailingComma
   6 OrderedImports
   2 EndOfLineComment
   1 GroupNumericLiterals
```

These are not bugs in the config — they are real formatting differences that only the full
`make fmt` pass resolves. A dry run of `make fmt` touches 26 of the repo's 27 Swift files
(all but `Sources/Focus.swift`), netting roughly +610/-371 lines in `Sources` and +127/-86 in
`Tests`.

## Plan

1. Keep `make lint` non-blocking in CI (`continue-on-error: true`) while the other in-flight
   branches land, so they do not have to fight a reformatted tree while rebasing.
2. After every in-flight branch has landed on `dist-makefile-ci`, run `make fmt` once as its
   own commit covering the whole tree.
3. Review the NeverForceUnwrap hits by hand at that point and decide whether to turn the rule
   on; 77 is too many to triage blind today.
4. Flip the CI step in `.github/workflows/ci.yml` to drop `continue-on-error: true`, making
   `make lint` blocking from then on.

## Disabled rules

`.swift-format` turns off four rules. Each one would fight a style the code already uses on
purpose. JSON cannot hold comments, so this file carries the reasons.

- **DoNotUseSemicolons**: The code joins short statements with a semicolon on one line, for
  example a single-line `if` body. This rule would force each statement onto its own line.
- **OneVariableDeclarationPerLine**: The code often declares related locals on one line, for
  example `let m = Model.shared, c = m.c`. This rule would split each declaration onto its own
  line.
- **AlwaysUseLowerCamelCase**: Test methods use a `testID_Description` name, for example
  `testFM17_ChainedDictationRestoresTheOriginalSource`. This rule reads the part after the
  underscore as a new word and would ask for a rename.
- **NeverForceUnwrap**: The code force-unwraps 77 times today, mostly on values it already
  guarantees are present, such as a literal dictionary lookup or a static table entry. Turning
  this rule on would flag all 77 at once instead of letting a maintainer review them by hand.
