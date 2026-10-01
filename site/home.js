(() => {
  'use strict';

  const language = new URLSearchParams(location.search).get('lang') === 'en' ? 'en' : 'zh';
  const copy = window.HIJACK_LOCALES[language];
  document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
  document.querySelectorAll('[data-i18n]').forEach(node => { node.textContent = copy[node.dataset.i18n]; });
  for (const attribute of ['aria-label', 'title', 'alt', 'content', 'src']) {
    document.querySelectorAll(`[data-i18n-${attribute}]`).forEach(node => {
      node.setAttribute(attribute, copy[node.getAttribute(`data-i18n-${attribute}`)]);
    });
  }
  const languageLink = document.querySelector('.language-link');
  languageLink.href = `?lang=${language === 'zh' ? 'en' : 'zh'}${location.hash}`;
  languageLink.lang = language === 'zh' ? 'en' : 'zh-CN';
  languageLink.querySelector('.language-label').textContent = language === 'zh' ? 'English' : '中文';
  languageLink.setAttribute('aria-label', language === 'zh' ? 'English version' : '中文版');
  document.querySelector('.brand').href = `?lang=${language}`;
  const phases = [
    { id: 'typing', duration: 700, source: copy.rime, status: copy.typingStatus, text: copy.placeholder, active: 'typing', direction: 'idle', detail: copy.previous },
    { id: 'speaking', duration: 1800, source: copy.wetype, status: copy.speakingStatus, text: copy.listening, active: 'voice', direction: 'out', detail: copy.previous },
    { id: 'restored', cueDuration: 950, source: copy.rime, status: copy.restoredStatus, text: copy.sample, active: 'typing', direction: 'back', detail: copy.continueTyping }
  ];
  const frame = document.querySelector('.app-window');
  const source = document.querySelector('#current-source');
  const status = document.querySelector('#demo-status');
  const sample = document.querySelector('#sample-text');
  const steps = document.querySelector('.source-steps');
  const stepItems = [...steps.querySelectorAll('[data-step]')];
  const replayButton = document.querySelector('#replay-switch');
  const backButton = document.querySelector('#back-to-meme');
  const typingDetail = document.querySelector('#typing-detail');
  let timer;

  function render(phase, cover = false) {
    frame.dataset.stage = phase.id;
    frame.dataset.view = cover ? 'cover' : 'demo';
    source.textContent = phase.source;
    status.textContent = phase.status;
    sample.textContent = phase.text;
    steps.dataset.direction = cover ? 'idle' : (phase.direction || 'idle');
    typingDetail.textContent = phase.detail;
    for (const item of stepItems) {
      if (!cover && item.dataset.step === phase.active) item.setAttribute('aria-current', 'step');
      else item.removeAttribute('aria-current');
    }
  }

  function stop() {
    clearTimeout(timer);
    timer = undefined;
  }

  function reset() {
    stop();
    render(phases[0], true);
  }

  function play() {
    stop();
    function advance(position) {
      const phase = phases[position];
      render(phase);
      if (phase.duration) {
        timer = setTimeout(() => advance(position + 1), phase.duration);
      } else if (phase.cueDuration) {
        timer = setTimeout(() => { steps.dataset.direction = 'idle'; }, phase.cueDuration);
      }
    }
    advance(0);
  }

  replayButton.addEventListener('click', play);
  backButton.addEventListener('click', () => {
    reset();
    replayButton.focus();
  });
  window.addEventListener('pagehide', stop);
  window.addEventListener('pageshow', event => { if (event.persisted) reset(); });

  const copyButtons = [...document.querySelectorAll('[data-copy]')];
  const copyStatus = document.querySelector('#copy-status');
  copyButtons.forEach(button => {
    button.addEventListener('click', async () => {
      const command = document.getElementById(button.dataset.copy);
      copyStatus.textContent = copy.copying;
      button.disabled = true;
      try {
        if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
        await navigator.clipboard.writeText(command.textContent.trim());
        copyButtons.forEach(item => { item.textContent = copy.copy; });
        button.textContent = copy.copiedLabel;
        copyStatus.textContent = copy.copied;
      } catch {
        const range = document.createRange();
        range.selectNodeContents(command);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        copyStatus.textContent = copy.copyFallback;
      } finally {
        button.disabled = false;
      }
    });
  });

  const guide = document.querySelector('#install-guide');
  guide.open = !window.matchMedia('(max-width: 760px)').matches || location.hash === '#install';
  document.querySelectorAll('a[href="#install"]').forEach(link => {
    link.addEventListener('click', () => { guide.open = true; });
  });
  window.addEventListener('hashchange', () => { if (location.hash === '#install') guide.open = true; });
})();
