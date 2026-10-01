(() => {
  'use strict';
  const isChinese = document.documentElement.lang.toLowerCase().startsWith('zh');
  const labels = isChinese ? {
    capsule: '微信语音输入', playing: '演示中…', replay: '↻ 再看一次', play: '▶ 播放切换演示',
    copying: '正在复制…', copied: '已复制。在终端中粘贴即可安装。',
    copyFallback: '已选中命令，请按 ⌘C 或 Ctrl+C 复制。'
  } : {
    capsule: 'WeType dictation', playing: 'Playing…', replay: '↻ Replay', play: '▶ Play the switch',
    copying: 'Copying…', copied: 'Copied. Paste into Terminal to install.',
    copyFallback: 'The command is selected. Press ⌘C or Ctrl+C to copy.'
  };
  const stages = isChinese ? [
    { source: '鼠须管', status: '正在使用鼠须管输入。', text: '下一句话，用说的。' },
    { source: '微信输入法', status: '按住按键，已切到微信输入法。', text: '正在听你说话…', capsule: '微信语音输入' },
    { source: '微信输入法', status: '已松开，等待微信输入法提交文字。', text: '把方案评审调整到周五吧。', capsule: '正在完成语音输入…' },
    { source: '鼠须管', status: '文字已提交，已恢复鼠须管。', text: '把方案评审调整到周五吧。' }
  ] : [
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
    document.querySelector('#capsule-label').textContent = stage.capsule || labels.capsule;
    document.querySelectorAll('[data-step]').forEach(item => {
      if (Number(item.dataset.step) === index) item.setAttribute('aria-current', 'step');
      else item.removeAttribute('aria-current');
    });
  }
  function clearTimers() { timers.forEach(clearTimeout); timers = []; }
  button.addEventListener('click', () => {
    clearTimers();
    button.disabled = true;
    button.textContent = labels.playing;
    showStage(1);
    timers.push(setTimeout(() => showStage(2), 1800));
    timers.push(setTimeout(() => {
      showStage(3);
      button.disabled = false;
      button.textContent = labels.replay;
    }, 3800));
  });
  window.addEventListener('pagehide', clearTimers);
  window.addEventListener('pageshow', event => {
    if (event.persisted) {
      clearTimers(); showStage(0); button.disabled = false; button.textContent = labels.play;
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
