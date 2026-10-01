(() => {
  'use strict';
  const stages = [
    { source: 'ABC', status: 'Typing with ABC.', text: 'Say the next sentence out loud.' },
    { source: 'WeType', status: 'Key held. Switched to WeType.', text: 'Listening…', capsule: 'WeType dictation' },
    { source: 'WeType', status: 'Key released. WeType is finishing.', text: 'Let’s move the review to Friday.', capsule: 'Finishing dictation…' },
    { source: 'ABC', status: 'Text submitted. ABC restored.', text: 'Let’s move the review to Friday.' }
  ];
  const appWindow = document.querySelector('.app-window');
  const button = document.querySelector('#play');
  let timers = [];
  function showStage(index) {
    const stage = stages[index];
    appWindow.dataset.stage = String(index);
    document.querySelector('#current-source').textContent = stage.source;
    document.querySelector('#demo-status').textContent = stage.status;
    document.querySelector('#sample-text').textContent = stage.text;
    document.querySelector('#capsule-label').textContent = stage.capsule || 'WeType dictation';
    document.querySelectorAll('[data-step]').forEach(item => {
      if (Number(item.dataset.step) === index) item.setAttribute('aria-current', 'step');
      else item.removeAttribute('aria-current');
    });
  }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  button.addEventListener('click', () => {
    clearTimers();
    button.disabled = true;
    button.textContent = 'Playing…';
    showStage(1);
    timers.push(setTimeout(() => showStage(2), 1800));
    timers.push(setTimeout(() => {
      showStage(3);
      button.disabled = false;
      button.textContent = '↻ Replay';
    }, 3800));
  });
  window.addEventListener('pagehide', clearTimers);
  window.addEventListener('pageshow', event => {
    if (event.persisted) {
      clearTimers(); showStage(0); button.disabled = false; button.textContent = '▶ Play the switch';
    }
  });
  document.querySelectorAll('[data-copy]').forEach(copyButton => {
    copyButton.addEventListener('click', async () => {
      const command = document.getElementById(copyButton.dataset.copy);
      const status = document.querySelector('#copy-status');
      status.textContent = 'Copying…';
      try {
        if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
        await navigator.clipboard.writeText(command.textContent.trim());
        status.textContent = 'Copied. Paste into Terminal to install.';
      } catch {
        const range = document.createRange(); range.selectNodeContents(command);
        const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        status.textContent = 'The command is selected. Press ⌘C or Ctrl+C to copy.';
      }
    });
  });
  const compact = window.matchMedia('(max-width: 760px)');
  const setGuide = () => { document.querySelector('#install-guide').open = !compact.matches; };
  setGuide(); compact.addEventListener('change', setGuide);
})();
