#!/bin/sh
# Regenerate docs/diagrams from the code. Same commit in, same diagrams out.
#   classes — SwiftPlantUML reads Sources/ (config: .swiftplantuml.yml); PlantUML renders it.
#     · No --sdk: with it, SourceKit can't resolve types declared in other files and prints them as "_".
#     · Member types come from the declarations, so stored properties spell out their type (`var x: Bool = false`).
#     · SwiftPlantUML draws inheritance and conformance only ("associations" are on its roadmap), so the
#       has-a edges are added here from its own output: a member whose type names another type in the diagram.
# Needs: brew install swiftplantuml; Java; PLANTUML_JAR (default ~/.local/share/plantuml/plantuml.jar).
set -e
cd "$(dirname "$0")/.."
JAR="${PLANTUML_JAR:-$HOME/.local/share/plantuml/plantuml.jar}"
OUT=docs/diagrams
mkdir -p "$OUT"
swiftplantuml classdiagram Sources --output consoleOnly > "$OUT/classes.puml"
python3 - "$OUT/classes.puml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
types = set(re.findall(r'^class "[^"]+" as (\w+)', text, re.M))
edges, owner = [], None
for line in text.splitlines():
    m = re.match(r'class "[^"]+" as (\w+)', line)
    if m: owner = m[1]; continue
    if line.startswith('}'): owner = None; continue
    m = re.match(r'\s*[~+\-#]?(?:\{static\} )?(\w+) : (.+)', line)
    if owner and m:
        for target in dict.fromkeys(re.findall(r'[A-Z]\w*', m[2])):
            if target in types and target != owner:
                edges.append((owner, target, m[1]))
pairs = {}
for a, b, name in edges: pairs.setdefault((a, b), []).append(name)   # one edge per pair, members listed on it
edges = [f'{a} --> {b} : {", ".join(sorted(set(names)))}' for (a, b), names in sorted(pairs.items())]
text = text.replace('@enduml', "' HAS-A (derived from member types)\n" + '\n'.join(edges) + '\n@enduml')
open(path, 'w').write(text)
print(f'{len(edges)} has-a edges')
PY
java -Djava.awt.headless=true -jar "$JAR" -tsvg "$OUT/classes.puml" 2>/dev/null
echo "wrote $OUT/classes.puml $OUT/classes.svg"
