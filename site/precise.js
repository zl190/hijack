(() => {
  'use strict';
  const isChinese = document.documentElement.lang.toLowerCase().startsWith('zh');
  const labels = isChinese ? {
    capsule: '微信语音输入', playing: '演示中…', replay: '▶ 播放演示', play: '▶ 播放演示',
    copying: '正在复制…', copied: '已复制，粘贴到终端运行。',
    copyFallback: '已选中命令，请按 ⌘C 或 Ctrl+C 复制。'
  } : {
    capsule: 'WeType dictation', playing: 'Playing…', replay: '↻ Replay', play: '▶ Play the switch',
    copying: 'Copying…', copied: 'Copied. Paste into Terminal to install.',
    copyFallback: 'The command is selected. Press ⌘C or Ctrl+C to copy.'
  };
  const stages = isChinese ? [
    { source: '鼠须管', status: '正在使用鼠须管输入。', text: '在这里输入…' },
    { source: '微信输入法', status: '按住按键，已切到微信输入法。', text: '正在听你说话…', capsule: '微信语音输入' },
    { source: '微信输入法', status: '已松开，等待微信输入法提交文字。', text: '周五下午三点开会。', capsule: '正在完成语音输入…' },
    { source: '鼠须管', status: '文字已提交，已恢复鼠须管。', text: '周五下午三点开会。' }
  ] : [
    { source: 'ABC', status: 'Typing with ABC.', text: 'Say the next sentence out loud.' },
    { source: 'WeType', status: 'Key held. Switched to WeType.', text: 'Listening…', capsule: 'WeType dictation' },
    { source: 'WeType', status: 'Key released. WeType is finishing.', text: 'Let’s move the review to Friday.', capsule: 'Finishing dictation…' },
    { source: 'ABC', status: 'Text submitted. ABC restored.', text: 'Let’s move the review to Friday.' }
  ];
  const appWindow = document.querySelector('.app-window');
  const button = document.querySelector('#play');
  const capsuleLabel = document.querySelector('#capsule-label');
  let timers = [];
  function showStage(index) {
    const stage = stages[index];
    appWindow.dataset.stage = String(index);
    if (isChinese) appWindow.dataset.view = 'demo';
    document.querySelector('#current-source').textContent = stage.source;
    document.querySelector('#demo-status').textContent = stage.status;
    document.querySelector('#sample-text').textContent = stage.text;
    if (capsuleLabel) capsuleLabel.textContent = stage.capsule || labels.capsule;
    const activeStep = isChinese ? Math.min(index, 2) : index;
    if (isChinese) {
      document.querySelector('#return-source').textContent = index === 2 ? stage.source : stages[0].source;
      document.querySelector('#return-detail').textContent = index === 2 ? '等待文字提交…' : index === 3 ? '已恢复，继续打字' : '文字上屏后切回';
    }
    document.querySelectorAll('[data-step]').forEach(item => {
      if (Number(item.dataset.step) === activeStep) item.setAttribute('aria-current', 'step');
      else item.removeAttribute('aria-current');
      item.querySelector('.step-select')?.setAttribute('aria-pressed', String(Number(item.dataset.step) === activeStep));
    });
  }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  button.addEventListener('click', () => {
    clearTimers();
    button.disabled = true;
    button.textContent = labels.playing;
    showStage(1);
    document.querySelector('#back-to-meme')?.focus();
    timers.push(setTimeout(() => showStage(2), 1800));
    timers.push(setTimeout(() => {
      showStage(3);
      button.disabled = false;
      button.textContent = labels.replay;
    }, 3800));
  });
  function showCover() {
    showStage(0);
    appWindow.dataset.view = 'cover';
    document.querySelectorAll('[data-step]').forEach(item => {
      item.removeAttribute('aria-current');
      item.querySelector('.step-select')?.setAttribute('aria-pressed', 'false');
    });
  }
  document.querySelectorAll('[data-go-stage]').forEach(stepButton => {
    stepButton.addEventListener('click', () => {
      clearTimers();
      const index = Number(stepButton.dataset.goStage);
      showStage(index);
      button.disabled = false;
      button.textContent = labels.play;
      if (index === 2) timers.push(setTimeout(() => showStage(3), 1800));
    });
  });
  document.querySelector('#back-to-meme')?.addEventListener('click', () => {
    clearTimers();
    showCover();
    button.disabled = false;
    button.textContent = labels.play;
    button.focus();
  });
  window.addEventListener('pagehide', clearTimers);
  window.addEventListener('pageshow', event => {
    if (event.persisted) {
      clearTimers(); if (isChinese) showCover(); else showStage(0); button.disabled = false; button.textContent = labels.play;
    }
  });
  document.querySelectorAll('[data-copy]').forEach(copyButton => {
    copyButton.addEventListener('click', async () => {
      const command = document.getElementById(copyButton.dataset.copy);
      const status = document.querySelector('#copy-status');
      status.textContent = labels.copying;
      try {
        if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
        await navigator.clipboard.writeText(command.textContent.trim());
        status.textContent = labels.copied;
      } catch {
        const range = document.createRange(); range.selectNodeContents(command);
        const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        status.textContent = labels.copyFallback;
      }
    });
  });
  const compact = window.matchMedia('(max-width: 760px)');
  const setGuide = () => { document.querySelector('#install-guide').open = !compact.matches; };
  setGuide(); compact.addEventListener('change', setGuide);
})();
