#!/bin/sh
# Build docs/architecture.html from docs/diagrams (run scripts/diagrams.sh and scripts/sequence.sh first).
# The diagrams are copied in as they are; only the short captions here are written by hand.
set -e
cd "$(dirname "$0")/.."
python3 - <<'PY'
import html, pathlib, subprocess
d = pathlib.Path('docs/diagrams')
commit = subprocess.run(['git', 'log', '-1', '--format=%h'], capture_output=True, text=True).stdout.strip()
def mermaid(name): return '<pre class="mermaid">\n' + html.escape(d.joinpath(name).read_text()) + '</pre>'
svg = d.joinpath('classes.svg').read_text()
svg = svg[svg.index('<svg'):]                       # drop the XML prolog so it can sit inline
sections = [
    ('system', '系统设计', '手工维护', 'docs/diagrams/architecture.mmd',
     '按键链上 Hijack 排第一，语音输入法自己的监听在后面。设置只有 config.json 一个真源，菜单、设置窗口和命令行都只改它。'
     '这是唯一一张靠人维护的图：代码改了而它没改，scripts/diagrams.sh 会提醒。', mermaid('architecture.mmd')),
    ('states', '状态机', '由代码生成 · 测试校验', 'Sources/Core/SessionMachine.swift → docs/diagrams/states.mmd',
     '每条边就是状态机函数在某种配置下的一个结果，方括号里是配置。只画从空闲出发真正走得到的状态；停在原地的情况（按键重复、过期事件）不画。'
     '代码改了图没重新生成，swift test 会失败。', mermaid('states.mmd')),
    ('classes', '类图', '由代码生成', 'SwiftPlantUML → docs/diagrams/classes.svg',
     '类型、字段、方法由 SwiftPlantUML 直接读 Sources/。实线箭头是「持有」：字段的类型是图里另一个类型，由脚本从工具输出推出；虚线三角是实现协议。',
     '<div class="svgwrap">' + svg + '</div>'),
    ('sequence', '时序图', '由实测生成', 'Hijack.log 或 Instruments 录制 → docs/diagrams/sequence.mmd',
     '一次真实的按住说话。时间来自 Hijack 自己的日志（每次说话一行汇总），或者 Instruments 录下的 signpost。', mermaid('sequence.mmd')),
]
nav = ''.join(f'<a href="#{i}">{t}</a>' for i, t, *_ in sections)
body = ''.join(f'''
<section id="{i}">
  <div class="head"><h2>{t}</h2><span class="tag">{tag}</span></div>
  <p>{html.escape(cap)}</p>
  <div class="figure">{fig}</div>
  <p class="src">来源 <code>{html.escape(src)}</code></p>
</section>''' for i, t, tag, src, cap, fig in sections)
page = f'''<title>Hijack Architecture</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;600&family=Noto+Sans+SC:wght@400;600&display=swap">
<style>
  :root {{ --bg:#f3f5f7; --surface:#ffffff; --ink:#1a1f26; --muted:#5b6573; --line:#dde2e8; --accent:#0e6a70; --chip:#eef1f4;
          --sans:"IBM Plex Sans","Noto Sans SC",system-ui,-apple-system,"PingFang SC",sans-serif; --mono:"IBM Plex Mono",ui-monospace,Menlo,monospace; }}
  @media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ color-scheme:dark; --bg:#12151a; --surface:#1a1e25; --ink:#e5e9ef; --muted:#9aa4b2; --line:#2b313b; --accent:#5bb8bd; --chip:#222831; }} }}
  :root[data-theme="dark"] {{ color-scheme:dark; --bg:#12151a; --surface:#1a1e25; --ink:#e5e9ef; --muted:#9aa4b2; --line:#2b313b; --accent:#5bb8bd; --chip:#222831; }}
  * {{ box-sizing:border-box; }}
  body {{ background:var(--bg); color:var(--ink); font-family:var(--sans); font-size:15px; line-height:1.65; padding-inline:20px; padding-block:0 56px; }}
  .wrap {{ max-width:1080px; margin:0 auto; }}
  header {{ padding-block:36px 16px; display:grid; gap:8px; }}
  .eyebrow {{ font-family:var(--mono); font-size:12px; letter-spacing:.08em; text-transform:uppercase; color:var(--accent); }}
  h1 {{ margin:0; font-size:clamp(26px,4vw,36px); line-height:1.2; font-weight:600; text-wrap:balance; }}
  .lede {{ margin:0; color:var(--muted); max-width:70ch; }}
  nav {{ position:sticky; top:env(safe-area-inset-top,0px); z-index:5; background:var(--bg); border-bottom:1px solid var(--line); display:flex; gap:4px; overflow-x:auto; padding-block:8px; }}
  nav a {{ color:var(--muted); text-decoration:none; padding:6px 12px; border-radius:6px; white-space:nowrap; font-size:14px; }}
  nav a:hover, nav a:focus-visible {{ background:var(--chip); color:var(--ink); outline:none; }}
  section {{ padding-block:36px 4px; display:grid; gap:12px; scroll-margin-top:56px; }}
  .head {{ display:flex; align-items:baseline; gap:12px; flex-wrap:wrap; }}
  h2 {{ margin:0; font-size:22px; font-weight:600; }}
  .tag {{ font-family:var(--mono); font-size:12px; color:var(--accent); background:var(--chip); padding:2px 8px; border-radius:4px; }}
  p {{ margin:0; max-width:72ch; }}
  .src {{ color:var(--muted); font-size:13px; }}
  code {{ font-family:var(--mono); font-size:.9em; background:var(--chip); padding:1px 5px; border-radius:3px; }}
  .figure {{ background:var(--surface); border:1px solid var(--line); border-radius:8px; padding:20px; overflow-x:auto; }}
  .figure pre.mermaid {{ margin:0; min-width:680px; background:transparent; }}
  .svgwrap {{ background:#ffffff; border-radius:6px; padding:8px; width:max-content; }}
  .svgwrap svg {{ display:block; max-width:none; height:auto; }}
  footer {{ margin-top:40px; padding-top:14px; border-top:1px solid var(--line); color:var(--muted); font-size:13px; }}
  @media (max-width:520px) {{ body {{ padding-inline:16px; }} .figure {{ padding:12px; }} }}
</style>
<div class="wrap">
  <header>
    <div class="eyebrow">Hijack · 架构</div>
    <h1>四张图，三张由代码和实测生成</h1>
    <p class="lede">同一个提交跑出来的图永远一样。重新生成：<code>scripts/diagrams.sh</code>（类图、状态图）、<code>scripts/sequence.sh</code>（时序图）、<code>scripts/architecture-page.sh</code>（本页）。</p>
  </header>
  <nav aria-label="章节">{nav}</nav>
  {body}
  <footer>根据 github.com/zl190/hijack 的 {commit} 生成</footer>
</div>
'''
pathlib.Path('docs/architecture.html').write_text(page)
print('wrote docs/architecture.html')
PY
