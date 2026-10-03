#!/bin/sh
# Turn an Instruments recording of Hijack into a Mermaid sequence diagram of one dictation, with measured times.
#   xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --attach Hijack --time-limit 30s --output x.trace
#   scripts/sequence.sh x.trace [N]     # N: which dictation in the recording (default 1)
# Instruments starts taking signposts a few seconds after the recording starts (6 s on a 2026 M-series Mac):
# wait ~8 s before dictating, or the press and the talk key are missing from the recording.
# The marks come from Engine (OSSignposter, Points of Interest): the "dictation" interval, its phases
# "starting" / "listening" / "waiting for text", and the events "talk key sent", "echo", "window gone".
# Each mark maps to one fixed line below, so the same recording always gives the same diagram.
set -e
cd "$(dirname "$0")/.."
TRACE="${1:?usage: scripts/sequence.sh recording.trace [N]}"
N="${2:-1}"
OUT=docs/diagrams/sequence.mmd
XML="$(mktemp)"
xcrun xctrace export --input "$TRACE" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' > "$XML"
python3 - "$XML" "$N" "$OUT" "$TRACE" <<'PY'
import sys, xml.etree.ElementTree as ET
xml_path, n, out, trace = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
root = ET.parse(xml_path).getroot()
seen = {}                                   # xctrace writes a repeated value once (id=) and refers to it (ref=)
def val(el):
    if el is None: return None
    if 'ref' in el.attrib: el = seen[el.attrib['ref']]
    return el
for el in root.iter():
    if 'id' in el.attrib: seen[el.attrib['id']] = el
marks = []
for row in root.iter('row'):
    cells = list(row)
    get = lambda tag: val(next((c for c in cells if c.tag == tag), None))
    sub = get('subsystem')
    if sub is None or sub.text != 'com.zl190.hijack': continue
    marks.append(dict(t=int(get('event-time').text) / 1e6, kind=get('event-type').text,
                      sid=get('os-signpost-identifier').text, name=get('signpost-name').text))
marks = [dict(m) for m in {tuple(sorted(m.items())) for m in marks}]   # the export repeats some rows
# One dictation = the marks sharing the id of a "dictation" Begin. Key-event intervals (shared exclusive id) are timed apart.
starts = sorted((m for m in marks if m['name'] == 'dictation' and m['kind'] == 'Begin'), key=lambda m: m['t'])
if len(starts) < n: sys.exit(f'only {len(starts)} dictation(s) in {trace}')
sid = starts[n - 1]['sid']
d = sorted((m for m in marks if m['sid'] == sid), key=lambda m: m['t'])
t0 = d[0]['t']
def at(name, kind):
    m = next((m for m in d if m['name'] == name and m['kind'] == kind), None)
    return None if m is None else m['t'] - t0
end = at('dictation', 'End') or d[-1]['t'] - t0
keys = [m for m in marks if m['name'] == 'key event']
spans, open_ = [], None
for m in sorted(keys, key=lambda m: m['t']):
    if m['kind'] == 'Begin': open_ = m['t']
    elif m['kind'] == 'End' and open_ is not None:
        if t0 <= open_ <= t0 + end: spans.append(m['t'] - open_)
        open_ = None
ms = lambda x: f'{x:.0f} ms' if x < 1000 else f'{x / 1000:.2f} s'
sent, echo, release, gone = at('talk key sent', 'Event'), at('echo', 'Event'), at('waiting for text', 'Begin'), at('window gone', 'Event')
L = ['sequenceDiagram', '  autonumber', '  actor U as 你', '  participant H as Hijack', '  participant V as 语音工具', '  participant I as 输入法系统',
     f'  Note over U,I: 第 {n} 次说话 · 共 {ms(end)} · 来源 {trace.rsplit("/", 1)[-1]}',
     '  U->>H: 按下触发键 (0 ms)', '  H->>I: 切到语音输入法']
if sent is not None: L.append(f'  H->>V: 说话键按下 ({ms(sent)})')
if echo is not None: L.append(f'  H-->>H: echo，键已发出 ({ms(echo)})')
if sent is not None and release is not None: L.append(f'  Note over H,V: 收音 {ms(release - sent)}')
if release is not None: L += [f'  U->>H: 松开 ({ms(release)})', '  H->>V: 说话键松开']
if gone is not None and release is not None: L.append(f'  V-->>H: 语音窗口消失，文字已上屏 (松开后 {ms(gone - release)})')
L.append(f'  H->>I: 切回原输入法 ({ms(end)})')
if spans: L.append(f'  Note over H: 期间 {len(spans)} 个按键事件，tap 回调最长 {max(spans):.2f} ms')
open(out, 'w').write('\n'.join(L) + '\n')
print(f'wrote {out}: dictation {n} of {len(starts)}, {ms(end)}')
PY
rm -f "$XML"
