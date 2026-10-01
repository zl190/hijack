(() => {
  'use strict';
  const scenes = {
    code: { title: 'A thought, right where you work', context: 'draft.ts', source: 'ABC', before: 'function saveDraft() {', after: '  return draft.persist();\n}', prefix: '// ', placeholder: 'Say this comment out loud.', text: 'Save locally, then sync to the cloud.' },
    mail: { title: 'A long reply, spoken first', context: 'Mail draft · Project update', source: 'Pinyin', before: 'Hi Alex,', after: 'Thanks!', prefix: '', placeholder: 'Say this reply out loud.', text: 'The direction looks good. There are two details I’d like to discuss.' },
    notes: { title: 'Catch a thought while it is fresh', context: 'My notes · A passing thought', source: 'Shuangpin', before: 'Something to come back to', after: 'Next: turn this into a plan.', prefix: '', placeholder: 'Say this thought out loud.', text: 'My tools should fit the way I think.' }
  };
  const windowEl = document.querySelector('.demo-window');
  const title = document.querySelector('#window-title');
  const context = document.querySelector('#editor-context');
  const lines = document.querySelector('#editor-lines');
  const source = document.querySelector('#input-source');
  const status = document.querySelector('#demo-status');
  const play = document.querySelector('#play-demo');
  const choices = [...document.querySelectorAll('[data-scene]')];
  let current = 'code';
  let timers = [];
  let run = 0;
  const clear = () => { timers.forEach(clearTimeout); timers = []; run += 1; };
  const later = (callback, delay) => { const token = run; timers.push(setTimeout(() => { if (token === run) callback(); }, delay)); };
  function phase(value) {
    windowEl.dataset.state = value;
    document.querySelectorAll('[data-phase]').forEach(el => el.classList.toggle('active', el.dataset.phase === value));
  }
  function paragraph(text) { const p = document.createElement('p'); p.textContent = text; return p; }
  function selectScene(key) {
    clear(); current = key;
    const scene = scenes[key];
    choices.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.scene === key)));
    title.textContent = scene.title; context.textContent = scene.context; source.textContent = scene.source;
    const line = paragraph(scene.prefix); line.className = 'dictation-line';
    const text = document.createElement('span'); text.id = 'dictation-text'; text.className = 'placeholder-text'; text.textContent = scene.placeholder;
    const caret = document.createElement('span'); caret.className = 'caret'; caret.setAttribute('aria-hidden', 'true');
    line.append(text, caret); lines.replaceChildren(paragraph(scene.before), line, paragraph(scene.after));
    status.textContent = `Your familiar ${scene.source} input source.`;
    play.disabled = false; play.textContent = '▶ Play demo'; phase('idle');
  }
  function playDemo() {
    clear();
    const scene = scenes[current];
    const text = document.querySelector('#dictation-text');
    phase('borrowing'); source.textContent = 'WeType'; play.disabled = true; play.textContent = 'Playing…';
    text.textContent = '…'; text.className = 'placeholder-text'; status.textContent = `Remember ${scene.source}. Borrow WeType voice.`;
    later(() => { text.className = ''; text.textContent = scene.text; }, 1100);
    later(() => { phase('restoring'); status.textContent = 'Release the key. Let the words settle.'; }, 2600);
    later(() => { phase('done'); source.textContent = scene.source; status.textContent = `Back to ${scene.source}. Back to your rhythm.`; play.disabled = false; play.textContent = '↻ Play again'; }, 3800);
  }
  choices.forEach(button => button.addEventListener('click', () => selectScene(button.dataset.scene)));
  document.querySelectorAll('[data-demo-link]').forEach(link => link.addEventListener('click', () => { selectScene(link.dataset.demoLink); play.focus({ preventScroll: true }); }));
  play.addEventListener('click', playDemo);
  window.addEventListener('pagehide', clear);
  document.querySelector('#copy-command').addEventListener('click', async () => {
    const feedback = document.querySelector('#copy-status');
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(document.querySelector('#install-command').textContent.trim());
      feedback.textContent = 'Copied. Paste into Terminal from your Hijack folder.';
    } catch {
      const range = document.createRange(); range.selectNodeContents(document.querySelector('#install-command'));
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      feedback.textContent = 'Copy was blocked. The command is selected; press ⌘C or Ctrl+C.';
    }
  });
  selectScene(current);
})();
