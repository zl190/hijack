#!/bin/sh
# A Mermaid sequence diagram of one dictation, with measured times. Same input, same diagram.
#   scripts/sequence.sh                 # the last dictation in ~/Library/Logs/Hijack.log (no recording needed)
#   scripts/sequence.sh x.trace [N]     # dictation N (default 1) of an Instruments recording, at full precision
# The log's per-dictation summary line already carries the times (talk key sent, echo, release, window
# gone, switch back), so the everyday diagram needs nothing running. A recording adds the tap-callback
# timings and comes from:
#   xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --attach Hijack --time-limit 30s --output x.trace
# Instruments starts taking signposts a few seconds after the recording starts (6 s on a 2026 M-series Mac):
# wait ~8 s before dictating, or the press and the talk key are missing from the recording.
set -e
cd "$(dirname "$0")/.."
OUT=docs/diagrams/sequence.mmd
SRC="${1:-$HOME/Library/Logs/Hijack.log}"
N="${2:-1}"
XML=""
case "$SRC" in
  *.trace|*.trace/)
    XML="$(mktemp)"
    xcrun xctrace export --input "$SRC" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' > "$XML" ;;
esac
python3 - "$SRC" "$N" "$OUT" "$XML" <<'PY'
import re, sys, xml.etree.ElementTree as ET
src, n, out, xml_path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
name = src.rstrip('/').rsplit('/', 1)[-1]

def from_trace():
    # Engine's signposts: "dictation" interval, phases starting / listening / waiting for text,
    # events talk key sent / echo / window gone, and a "key event" interval per tap callback.
    root = ET.parse(xml_path).getroot()
    seen = {el.attrib['id']: el for el in root.iter() if 'id' in el.attrib}   # repeated values: id= once, ref= after
    val = lambda el: None if el is None else seen[el.attrib['ref']] if 'ref' in el.attrib else el
    marks = set()                                                              # the export repeats some rows
    for row in root.iter('row'):
        get = lambda tag: val(next((c for c in row if c.tag == tag), None))
        sub = get('subsystem')
        if sub is None or sub.text != 'com.zl190.hijack': continue
        marks.add((int(get('event-time').text) / 1e6, get('event-type').text,
                   get('os-signpost-identifier').text, get('signpost-name').text))
    starts = sorted(m for m in marks if m[3] == 'dictation' and m[1] == 'Begin')
    if len(starts) < n: sys.exit(f'only {len(starts)} complete dictation(s) in {name}')
    sid, t0 = starts[n - 1][2], starts[n - 1][0]
    d = [m for m in marks if m[2] == sid]
    at = lambda nm, kind: next((t - t0 for t, k, _, x in sorted(d) if x == nm and k == kind), None)
    end = at('dictation', 'End')
    spans, open_ = [], None
    for t, k, _, x in sorted(m for m in marks if m[3] == 'key event'):
        if k == 'Begin': open_ = t
        elif k == 'End' and open_ is not None:
            if end is not None and t0 <= open_ <= t0 + end: spans.append(t - open_)
            open_ = None
    return dict(label=f'第 {n} 次说话', sent=at('talk key sent', 'Event'), echo=at('echo', 'Event'),
                release=at('waiting for text', 'Begin'), gone=at('window gone', 'Event'), end=end, spans=spans)

def from_log():
    # The summary line Engine.summary() writes, e.g.
    # 2026-10-03 19:59:58.698 dictation WeType (hold): held 5.4s, Fn sent after 242ms, window closed 1401ms after
    #   release, back after 1.56s | echo after 243ms, ...
    lines = [l for l in open(src, encoding='utf-8', errors='replace') if ' dictation ' in l and ' sent after ' in l]
    if not lines: sys.exit(f'no dictation with a talk key in {src}')
    l = lines[-n]
    num = lambda pat: (lambda m: float(m[1]) if m else None)(re.search(pat, l))
    held, sent, echo = num(r'held ([\d.]+)s'), num(r'sent after (\d+)ms'), num(r'echo after (\d+)ms')
    gone, back = num(r'window closed (\d+)ms after release'), num(r'back after ([\d.]+)s')
    release = held * 1000
    when = l[:19]
    return dict(label=f'{when} 的说话 (日志，按住时长精确到 10 ms)', sent=sent, echo=echo, release=release,
                gone=None if gone is None else release + gone, end=None if back is None else release + back * 1000, spans=[])

r = from_trace() if xml_path else from_log()
ms = lambda x: f'{x:.0f} ms' if x < 1000 else f'{x / 1000:.2f} s'
L = ['sequenceDiagram', '  autonumber', '  actor U as 你', '  participant H as Hijack', '  participant V as 语音工具',
     '  participant I as 输入法系统', f'  Note over U,I: {r["label"]} · 来源 {name}',
     '  U->>H: 按下触发键 (0 ms)', '  H->>I: 切到语音输入法']
if r['sent'] is not None: L.append(f'  H->>V: 说话键按下 ({ms(r["sent"])})')
if r['echo'] is not None: L.append(f'  H-->>H: echo，键已发出 ({ms(r["echo"])})')
if r['sent'] is not None and r['release'] is not None: L.append(f'  Note over H,V: 收音 {ms(r["release"] - r["sent"])}')
if r['release'] is not None: L += [f'  U->>H: 松开 ({ms(r["release"])})', '  H->>V: 说话键松开']
if r['gone'] is not None: L.append(f'  V-->>H: 语音窗口消失，文字已上屏 (松开后 {ms(r["gone"] - r["release"])})')
if r['end'] is not None: L.append(f'  H->>I: 切回原输入法 ({ms(r["end"])})')
if r['spans']: L.append(f'  Note over H: 期间 {len(r["spans"])} 个按键事件，tap 回调最长 {max(r["spans"]):.2f} ms')
open(out, 'w').write('\n'.join(L) + '\n')
print(f'wrote {out} from {name}')
PY
[ -n "$XML" ] && rm -f "$XML"
exit 0
