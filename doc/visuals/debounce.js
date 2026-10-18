// An animated timeline of watch's looks and the debounce (W1, W3): every tick is one look at
// the files. A change starts a wait, a further change restarts it, and sync runs when a look
// finds the files quiet after a change.
//
//   <div class="lm-debounce" data-changes="2 3 4 9"></div>
//   <script src="visuals/debounce.js"></script>
// data-changes lists the looks that find a change. The quiet time is one look.

(function () {
  'use strict';

  function simulate(changes, total) {
    const frames = [];
    let waiting = false, last = -1;
    for (let tick = 0; tick < total; tick++) {
      const changed = changes.includes(tick);
      let run = false, text;
      if (changed) {
        text = waiting
          ? `Look ${tick}: a file changed again. The wait starts over.`
          : `Look ${tick}: a file changed. The wait starts. Sync does not run yet, since more saves may follow.`;
        waiting = true; last = tick;
      } else if (waiting && tick - last >= 1) {
        text = `Look ${tick}: nothing changed, and the files have been quiet for one interval. Sync runs now, once, for all the changes since look ${changes.find((c) => c <= last && !frames.some((f) => f.run && f.tick > c)) ?? last}.`;
        run = true; waiting = false;
      } else {
        text = `Look ${tick}: nothing changed, and nothing is waiting.`;
      }
      frames.push({ tick, changed, run, waiting, text });
    }
    return frames;
  }

  const css = `
.lm-debounce { margin: 1.25em 0; border: 1px solid #e5e7eb; border-radius: 6px; padding: 12px; background: #fcfcfd; }
.lm-debounce canvas { display: block; width: 100%; }
.lm-debounce .lm-text { min-height: 3em; margin: .5em 0; font-size: .95em; line-height: 1.45; color: #1f2937; }
.lm-debounce .lm-controls { display: flex; gap: .5em; align-items: center; font-size: .85em; }
.lm-debounce button { font: inherit; padding: .25em .8em; border: 1px solid #cbd5e1; border-radius: 4px; background: white; cursor: pointer; }
.lm-debounce button:hover { background: #f1f5f9; }
.lm-debounce .lm-count { color: #6b7280; margin-left: auto; }
`;

  function mount(el) {
    const changes = (el.dataset.changes || '').split(/\s+/).filter(Boolean).map(Number);
    const total = Math.max(...changes, 0) + 4;
    const frames = simulate(changes, total);
    const canvas = document.createElement('canvas');
    const text = document.createElement('div'); text.className = 'lm-text';
    const controls = document.createElement('div'); controls.className = 'lm-controls';
    const count = document.createElement('span'); count.className = 'lm-count';
    const button = (label, fn) => { const b = document.createElement('button'); b.textContent = label; b.onclick = fn; controls.appendChild(b); return b; };
    el.append(canvas, text, controls);
    let at = 0, timer = null;
    button('◀ Back', () => { stop(); show(Math.max(0, at - 1)); });
    const play = button('▶ Play', () => (timer ? stop() : start()));
    button('Step ▶', () => { stop(); show(Math.min(frames.length - 1, at + 1)); });
    button('Restart', () => { stop(); show(0); });
    controls.appendChild(count);
    function start() { if (at >= frames.length - 1) show(0); play.textContent = '❚❚ Pause'; timer = setInterval(() => (at >= frames.length - 1 ? stop() : show(at + 1)), 900); }
    function stop() { clearInterval(timer); timer = null; play.textContent = '▶ Play'; }
    function show(i) { at = i; draw(canvas, frames, at); text.textContent = frames[at].text; count.textContent = `${at + 1} / ${frames.length}`; }
    new ResizeObserver(() => show(at)).observe(el);
    show(0);
  }

  function draw(canvas, frames, at) {
    const width = canvas.parentElement.clientWidth - 24, height = 130;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = width * dpr; canvas.height = height * dpr; canvas.style.height = height + 'px';
    const g = canvas.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, width, height);
    const left = 70, step = (width - left - 20) / frames.length, line = 78;
    g.font = '12px system-ui, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
    g.fillStyle = '#6b7280'; g.textAlign = 'left'; g.fillText('looks', 8, line); g.fillText('changes', 8, line - 36); g.fillText('sync', 8, line + 32);
    g.textAlign = 'center';
    g.strokeStyle = '#d1d5db'; g.beginPath(); g.moveTo(left, line); g.lineTo(width - 10, line); g.stroke();
    // The wait: a band from a change to the look that finds the files quiet.
    let from = null;
    frames.forEach((f, i) => {
      if (i > at) return;
      const x = left + (i + 0.5) * step;
      if (f.changed && from === null) from = i;
      if (f.run && from !== null) { g.fillStyle = 'rgba(37, 99, 235, 0.12)'; g.fillRect(left + (from + 0.5) * step, line - 14, (i - from) * step, 28); from = null; }
      g.fillStyle = f.changed ? '#d97706' : '#9ca3af';
      g.beginPath(); g.arc(x, line, f.changed ? 6 : 4, 0, Math.PI * 2); g.fill();
      g.fillStyle = '#6b7280'; g.fillText(String(i), x, line + 16);
      if (f.changed) { g.fillStyle = '#d97706'; g.fillText('saved', x, line - 36); }
      if (f.run) { g.fillStyle = '#2563eb'; g.fillRect(x - 24, line + 24, 48, 18); g.fillStyle = 'white'; g.fillText('run', x, line + 33); }
    });
    if (from !== null) { g.fillStyle = 'rgba(37, 99, 235, 0.12)'; g.fillRect(left + (from + 0.5) * step, line - 14, (at - from) * step, 28); }
    const x = left + (at + 0.5) * step;
    g.strokeStyle = '#111827'; g.lineWidth = 2; g.beginPath(); g.arc(x, line, 9, 0, Math.PI * 2); g.stroke(); g.lineWidth = 1;
  }

  function init() {
    if (!document.getElementById('lm-debounce-style')) {
      const style = document.createElement('style'); style.id = 'lm-debounce-style'; style.textContent = css; document.head.appendChild(style);
    }
    document.querySelectorAll('.lm-debounce').forEach(mount);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
