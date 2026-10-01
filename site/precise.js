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
  function setPlayButton(disabled, text) {
    if (!button) return;
    button.disabled = disabled;
    button.textContent = text;
  }
  function showStage(index) {
    const stage = stages[index];
    appWindow.dataset.stage = String(index);
    if (isChinese) appWindow.dataset.view = 'demo';
    document.querySelector('#current-source').textContent = stage.source;
    document.querySelector('#demo-status').textContent = stage.status;
    document.querySelector('#sample-text').textContent = stage.text;
    if (capsuleLabel) capsuleLabel.textContent = stage.capsule || labels.capsule;
    const activeStep = isChinese ? (index === 1 || index === 2 ? 1 : 0) : index;
    if (isChinese) {
      document.querySelector('.source-steps').dataset.direction = ['idle', 'out', 'waiting', 'back'][index];
      document.querySelector('#typing-detail').textContent = index === 3 ? '继续打字' : '原输入法';
      document.querySelector('#voice-detail').textContent = '语音输入';
    }
    document.querySelectorAll('[data-step]').forEach(item => {
      if (Number(item.dataset.step) === activeStep) item.setAttribute('aria-current', 'step');
      else item.removeAttribute('aria-current');
      item.querySelector('.step-select')?.setAttribute('aria-pressed', String(Number(item.dataset.step) === activeStep));
    });
  }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  function playFrom(startIndex) {
    clearTimers();
    setPlayButton(true, labels.playing);
    showStage(startIndex);
    const sequence = isChinese ? [0, 1, 3] : [0, 1, 2, 3];
    const durations = [700, 1800, 2000];
    let elapsed = 0;
    for (let position = sequence.indexOf(startIndex) + 1; position < sequence.length; position += 1) {
      const index = sequence[position];
      elapsed += durations[sequence[position - 1]];
      timers.push(setTimeout(() => {
        showStage(index);
        if (index === stages.length - 1) {
          setPlayButton(false, labels.replay);
        }
      }, elapsed));
    }
  }
  button?.addEventListener('click', () => {
    playFrom(isChinese ? 0 : 1);
    document.querySelector('[data-go-stage="0"]')?.focus();
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
      playFrom(Number(stepButton.dataset.goStage));
    });
  });
  document.querySelector('#back-to-meme')?.addEventListener('click', () => {
    clearTimers();
    showCover();
    setPlayButton(false, labels.play);
    (button || document.querySelector('[data-go-stage="0"]'))?.focus();
  });
  window.addEventListener('pagehide', clearTimers);
  window.addEventListener('pageshow', event => {
    if (event.persisted) {
      clearTimers(); if (isChinese) showCover(); else showStage(0); setPlayButton(false, labels.play);
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
