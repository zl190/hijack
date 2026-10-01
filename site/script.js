(() => {
  'use strict';
  const scenes = {
    voice: {
      headline: 'WeType’s voice.', payoff: 'Your keyboard.',
      description: 'Keep the input method you love. Borrow WeType’s voice when a thought is easier to say, then return to your familiar keyboard.',
      action: 'Try the voice example', destination: '#install',
      title: 'A thought, right where you work', context: 'draft.ts', source: 'ABC', borrowed: 'Voice',
      availability: 'Voice example · available now', note: 'Example: WeType voice. Illustrative only; no audio recorded.',
      capability: 'Borrow voice', borrowing: 'Borrowing voice input',
      before: 'function saveDraft() {', after: '  return draft.persist();\n}', prefix: '// ',
      placeholder: 'Say this comment out loud.', text: 'Save locally, then sync to the cloud.',
      idle: 'Your keyboard. Your editor. Your setup.', active: 'Borrow a voice. Keep your keyboard.',
      settling: 'Release the key. Let the words settle.', done: 'Back to ABC. Back to your rhythm.'
    },
    translate: {
      headline: 'A new language.', payoff: 'Your own flow.',
      description: 'A passage stops you mid-read. Imagine borrowing a translator for a moment, then carrying on in the same article.',
      action: 'See the borrowing pattern', destination: '#how-it-works',
      title: 'Keep your place in the story', context: 'Reading · A selected passage', source: 'Reader', borrowed: 'Translate',
      availability: 'Translation · concept only', note: 'Illustrative concept. Translation is not available in Hijack today.',
      capability: 'Translate', borrowing: 'Borrowing a translation',
      before: '“À chacun sa façon de travailler.”', after: 'Your article. Your place. Your notes.', prefix: '',
      placeholder: 'A little help with this passage.', text: '“Everyone has their own way of working.”',
      idle: 'A passage to understand. A place to keep.', active: 'Imagine borrowing just the translation.',
      settling: 'A little clarity, in the same context.', done: 'Back to the article. Keep reading.'
    },
    ocr: {
      headline: 'Text in a picture.', payoff: 'Your next idea.',
      description: 'A screenshot has the words you need. Imagine borrowing text recognition and bringing the result into your own notes.',
      action: 'See the borrowing pattern', destination: '#how-it-works',
      title: 'From a picture to your own notes', context: 'Notebook · A captured idea', source: 'Notes', borrowed: 'OCR',
      availability: 'Text capture · concept only', note: 'Illustrative concept. Text capture is not available in Hijack today.',
      capability: 'Capture text', borrowing: 'Borrowing text recognition',
      before: 'Image: workshop-whiteboard.png', after: 'Keep the words in your own notebook.', prefix: '',
      placeholder: 'There is a thought worth keeping.', text: 'Make the tools fit the way you think.',
      idle: 'The words you need are inside a picture.', active: 'Imagine borrowing text recognition.',
      settling: 'A useful sentence, ready for your notes.', done: 'Back to your notebook. Make it your own.'
    }
  };
  const windowEl = document.querySelector('.demo-window');
  const title = document.querySelector('#window-title');
  const context = document.querySelector('#editor-context');
  const lines = document.querySelector('#editor-lines');
  const source = document.querySelector('#input-source');
  const status = document.querySelector('#demo-status');
  const play = document.querySelector('#play-demo');
  const choices = [...document.querySelectorAll('[data-scene]')];
  let current = 'voice';
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
    document.querySelector('#story-headline').textContent = scene.headline;
    document.querySelector('#story-payoff').textContent = scene.payoff;
    document.querySelector('#story-description').textContent = scene.description;
    document.querySelector('#story-action-label').textContent = scene.action;
    document.querySelector('#story-action').setAttribute('href', scene.destination);
    title.textContent = scene.title; context.textContent = scene.context; source.textContent = scene.source;
    document.querySelector('#demo-availability').textContent = scene.availability;
    document.querySelector('#demo-note').textContent = scene.note;
    document.querySelector('#journey-capability').textContent = scene.capability;
    document.querySelector('#borrow-label').textContent = scene.borrowing;
    const line = paragraph(scene.prefix); line.className = 'dictation-line';
    const text = document.createElement('span'); text.id = 'dictation-text'; text.className = 'placeholder-text'; text.textContent = scene.placeholder;
    const caret = document.createElement('span'); caret.className = 'caret'; caret.setAttribute('aria-hidden', 'true');
    line.append(text, caret); lines.replaceChildren(paragraph(scene.before), line, paragraph(scene.after));
    status.textContent = scene.idle;
    play.disabled = false; play.textContent = '▶ Play demo'; phase('idle');
  }
  function playDemo() {
    clear();
    const scene = scenes[current];
    const text = document.querySelector('#dictation-text');
    phase('borrowing'); source.textContent = scene.borrowed; play.disabled = true; play.textContent = 'Playing…';
    text.textContent = '…'; text.className = 'placeholder-text'; status.textContent = scene.active;
    later(() => { text.className = ''; text.textContent = scene.text; }, 1100);
    later(() => { phase('restoring'); status.textContent = scene.settling; }, 2600);
    later(() => { phase('done'); source.textContent = scene.source; status.textContent = scene.done; play.disabled = false; play.textContent = '↻ Play again'; }, 3800);
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
  // Keep the brief mobile page readable; users expand installation when they need it.
  const compactLayout = window.matchMedia('(max-width: 900px)');
  const installGuide = document.querySelector('#install-guide');
  const setGuideDefault = () => { installGuide.open = !compactLayout.matches; };
  setGuideDefault();
  compactLayout.addEventListener('change', setGuideDefault);
  selectScene(current);
})();
