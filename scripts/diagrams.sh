#!/bin/sh
# Regenerate docs/diagrams from the code. Same commit in, same diagrams out.
#   classes  — SwiftPlantUML reads Sources/ (config: .swiftplantuml.yml), PlantUML renders it.
#              Known gaps of the tool: no "has-a" edges (only inheritance / conformance), members whose type is
#              inferred show as "_", and an enum's `case a, b, c` line shows only its first case.
# Needs: brew install swiftplantuml; Java; PLANTUML_JAR (default ~/.local/share/plantuml/plantuml.jar).
set -e
cd "$(dirname "$0")/.."
JAR="${PLANTUML_JAR:-$HOME/.local/share/plantuml/plantuml.jar}"
OUT=docs/diagrams
mkdir -p "$OUT"
swiftplantuml classdiagram Sources --output consoleOnly --sdk "$(xcrun --show-sdk-path -sdk macosx)" > "$OUT/classes.puml"
java -Djava.awt.headless=true -jar "$JAR" -tsvg "$OUT/classes.puml" 2>/dev/null
echo "wrote $OUT/classes.puml $OUT/classes.svg"
