# swift-format

Hijack uses Xcode's bundled `swift-format`, run as `xcrun swift-format`. It is not on `PATH`.

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
