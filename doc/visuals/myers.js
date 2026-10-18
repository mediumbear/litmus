// An animated picture of the line diff in src/diff.zig: trimming the common start and
// end, Myers' search round by round, the walk back, and the hunks.
//
// Use it from a document with a passthrough block:
//   <div class="lm-myers" data-base="x A B C y" data-changed="x C B y"></div>
//   <script src="visuals/myers.js"></script>
// Each word of data-base and data-changed stands for one line.

(function () {
  'use strict';

  // The same algorithm as diff.zig, recording every step so that it can be drawn.
  function run(base, changed) {
    let start = 0;
    while (start < base.length && start < changed.length && base[start] === changed[start]) start++;
    let end = 0;
    while (end < base.length - start && end < changed.length - start &&
      base[base.length - 1 - end] === changed[changed.length - 1 - end]) end++;
    const a = base.slice(start, base.length - end);
    const b = changed.slice(start, changed.length - end);
    const n = a.length, m = b.length;

    const offset = n + m + 1;
    const v = new Array(2 * offset + 1).fill(0);
    const trace = [];
    const rounds = []; // rounds[d] = [{ k, from, mid, to }]
    let found = -1;
    for (let d = 0; d <= n + m && found < 0; d++) {
      trace.push(v.slice());
      const steps = [];
      for (let k = -d; k <= d; k += 2) {
        const down = k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1]);
        let x = down ? v[offset + k + 1] : v[offset + k - 1] + 1;
        let y = x - k;
        let from;
        if (d === 0) from = [0, 0];
        else if (down) from = [v[offset + k + 1], v[offset + k + 1] - (k + 1)];
        else from = [v[offset + k - 1], v[offset + k - 1] - (k - 1)];
        const mid = [x, y];
        while (x < n && y < m && a[x] === b[y]) { x++; y++; }
        v[offset + k] = x;
        // A diagonal can run off the grid; such a step can never lead to the end.
        steps.push({ k, from, mid, to: [x, y], down, outside: x > n || y > m });
        if (x >= n && y >= m) { found = d; break; }
      }
      rounds.push(steps);
    }

    // The walk back, as in diff.zig: each round gives one edit and a diagonal.
    const deleted = new Array(n).fill(false);
    const inserted = new Array(m).fill(false);
    const path = []; // from the end back to the start: { from, mid, to }
    let x = n, y = m;
    for (let d = found; d > 0; d--) {
      const before = trace[d];
      const k = x - y;
      const down = k === -d || (k !== d && before[offset + k - 1] < before[offset + k + 1]);
      const pk = down ? k + 1 : k - 1;
      const px = before[offset + pk];
      const py = px - pk;
      const mid = down ? [px, py + 1] : [px + 1, py];
      if (down) inserted[py] = true; else deleted[px] = true;
      path.push({ from: [px, py], mid, to: [x, y] });
      x = px; y = py;
    }
    if (x > 0 || y > 0) path.push({ from: [0, 0], mid: [0, 0], to: [x, y] });
    path.reverse();

    // Lines that were neither deleted nor inserted pair up; what lies between is a hunk.
    const hunks = [];
    let i = 0, j = 0;
    while (i < n || j < m) {
      if (i < n && !deleted[i] && j < m && !inserted[j]) { i++; j++; continue; }
      const fi = i, fj = j;
      while (i < n && deleted[i]) i++;
      while (j < m && inserted[j]) j++;
      hunks.push({ a: start + fi, a_end: start + i, b: start + fj, b_end: start + j });
    }
    return { base, changed, start, end, a, b, n, m, rounds, found, path, deleted, inserted, hunks };
  }

  // The frames of the animation. Each frame says what is shown, and the words for it.
  function frames(r) {
    const f = [];
    const total = r.rounds.reduce((s, steps) => s + steps.filter((x) => !x.outside).length, 0);
    f.push({ stage: 'lines', text: `The base has ${r.base.length} lines and the changed text has ${r.changed.length}. Each letter stands for a whole line.` });
    f.push({ stage: 'trim', text: r.start + r.end > 0
      ? `First, the lines both texts share at the start (${r.start}) and at the end (${r.end}) are set aside, in grey. They cannot be part of any hunk, and most edits are small, so this alone often settles the diff.`
      : 'No lines are shared at the start or the end, so nothing is trimmed.' });
    f.push({ stage: 'grid', text: `What is left is a grid: base lines go across, changed lines go down. Moving right deletes a base line, moving down inserts a changed line, and a dotted diagonal is a line that is the same in both, which costs nothing. The diff is the cheapest way from the top left to the bottom right.` });
    let shown = 0;
    r.rounds.forEach((steps, d) => {
      steps.forEach((s, idx) => {
        if (s.outside) return;
        shown++;
        const edit = d === 0 ? 'no edit' : (s.down ? `inserting changed line ${s.mid[1]}` : `deleting base line ${s.mid[0]}`);
        f.push({ stage: 'search', round: d, upto: idx, text: `Round ${d}: with ${d} edit${d === 1 ? '' : 's'}, diagonal ${s.k} is reached by ${edit}, and then follows free diagonals as far as they go, to (${s.to[0]}, ${s.to[1]}).` });
      });
    });
    f.push({ stage: 'found', text: `Round ${r.found} reaches the bottom right corner: ${r.found} edits is the fewest that turn the middle of the base into the middle of the changed text. Myers' search looked at ${total} places to know that.` });
    for (let p = r.path.length - 1; p >= 0; p--) {
      f.push({ stage: 'back', upto: p, text: 'Walking back from the end, each round says which way it came: from the left (a deleted line) or from above (an inserted line), after a run of diagonals.' });
    }
    f.push({ stage: 'hunks', text: hunkText(r) });
    return f;
  }

  function hunkText(r) {
    if (r.hunks.length === 0) return 'The texts are the same, so there are no hunks.';
    const parts = r.hunks.map((h) => {
      const del = h.a_end - h.a, ins = h.b_end - h.b;
      return `base ${h.a}..${h.a_end} → changed ${h.b}..${h.b_end} (${del} out, ${ins} in)`;
    });
    return `Lines on the path's diagonals pair up. Between two pairs, the marked lines form a hunk. Counting lines from 0 in the whole texts: ${parts.join('; ')}.`;
  }

  const css = `
.lm-myers { margin: 1.25em 0; border: 1px solid #e5e7eb; border-radius: 6px; padding: 12px; background: #fcfcfd; }
.lm-myers canvas { display: block; width: 100%; }
.lm-myers .lm-text { min-height: 4.5em; margin: .5em 0; font-size: .95em; line-height: 1.45; color: #1f2937; }
.lm-myers .lm-controls { display: flex; gap: .5em; align-items: center; flex-wrap: wrap; font-size: .85em; }
.lm-myers button { font: inherit; padding: .25em .8em; border: 1px solid #cbd5e1; border-radius: 4px; background: white; cursor: pointer; }
.lm-myers button:hover { background: #f1f5f9; }
.lm-myers .lm-count { color: #6b7280; margin-left: auto; }
`;

  const colors = {
    grid: '#e5e7eb', diagonal: '#94a3b8', trimmed: '#cbd5e1', text: '#111827', muted: '#9ca3af',
    path: '#1d4ed8', deleted: 'rgba(220, 38, 38, 0.13)', inserted: 'rgba(22, 163, 74, 0.13)',
    deletedChip: '#dc2626', insertedChip: '#16a34a',
  };
  const roundColor = (d) => `hsl(${(d * 47 + 20) % 360} 70% 45%)`;

  function mount(el) {
    const base = (el.dataset.base || '').split(/\s+/).filter(Boolean);
    const changed = (el.dataset.changed || '').split(/\s+/).filter(Boolean);
    const r = run(base, changed);
    const fs = frames(r);

    const canvas = document.createElement('canvas');
    const text = document.createElement('div');
    text.className = 'lm-text';
    const controls = document.createElement('div');
    controls.className = 'lm-controls';
    const button = (label, fn) => { const b = document.createElement('button'); b.textContent = label; b.onclick = fn; controls.appendChild(b); return b; };
    const count = document.createElement('span');
    count.className = 'lm-count';
    el.append(canvas, text, controls);

    let at = 0, timer = null;
    const back = button('◀ Back', () => { stop(); show(Math.max(0, at - 1)); });
    const play = button('▶ Play', () => (timer ? stop() : start()));
    button('Step ▶', () => { stop(); show(Math.min(fs.length - 1, at + 1)); });
    button('Restart', () => { stop(); show(0); });
    controls.appendChild(count);
    void back;

    function start() {
      if (at >= fs.length - 1) show(0);
      play.textContent = '❚❚ Pause';
      timer = setInterval(() => { if (at >= fs.length - 1) stop(); else show(at + 1); }, 1100);
    }
    function stop() { clearInterval(timer); timer = null; play.textContent = '▶ Play'; }
    function show(i) { at = i; draw(canvas, r, fs, at); text.textContent = fs[at].text; count.textContent = `${at + 1} / ${fs.length}`; }

    new ResizeObserver(() => show(at)).observe(el);
    show(0);
  }

  function draw(canvas, r, fs, at) {
    const frame = fs[at];
    const stage = ['lines', 'trim', 'grid', 'search', 'found', 'back', 'hunks'].indexOf(frame.stage);
    const width = canvas.parentElement.clientWidth - 24;
    const cell = Math.max(26, Math.min(52, Math.floor((width - 140) / (r.base.length + 1))));
    const ox = 80 + r.start * 0, oy = 70; // the grid's top left corner
    const gridW = r.n * cell, gridH = r.m * cell;
    const height = oy + Math.max(gridH, 0) + 60;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = width * dpr; canvas.height = height * dpr;
    canvas.style.height = height + 'px';
    const g = canvas.getContext('2d');
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, width, height);
    g.font = '14px ui-monospace, SFMono-Regular, Menlo, monospace';
    g.textAlign = 'center'; g.textBaseline = 'middle';

    const px = (i) => ox + i * cell;
    const py = (j) => oy + j * cell;
    const trimmed = stage >= 1;

    // Hunk bands under everything else.
    if (stage >= 6) {
      r.deleted.forEach((d, i) => { if (d) { g.fillStyle = colors.deleted; g.fillRect(px(i), oy - 40, cell, gridH + 40); } });
      r.inserted.forEach((d, j) => { if (d) { g.fillStyle = colors.inserted; g.fillRect(ox - 60, py(j), gridW + 60, cell); } });
    }

    // The lines as chips: the base across the top, the changed text down the left.
    const chip = (label, x, y, color, strike) => {
      g.fillStyle = color; g.fillText(label, x, y);
      if (strike) { g.strokeStyle = color; g.beginPath(); g.moveTo(x - 7, y); g.lineTo(x + 7, y); g.stroke(); }
    };
    r.base.forEach((line, i) => {
      const inMiddle = i >= r.start && i < r.base.length - r.end;
      const mi = i - r.start;
      let x;
      if (!trimmed) x = ox + (i + 0.5) * cell * (r.n / Math.max(1, r.base.length));
      else if (i < r.start) x = ox - 22 - (r.start - 1 - i) * 18;
      else if (!inMiddle) x = ox + gridW + 22 + (i - (r.base.length - r.end)) * 18;
      else x = px(mi);
      const color = trimmed && !inMiddle ? colors.trimmed : (stage >= 6 && r.deleted[mi] ? colors.deletedChip : colors.text);
      chip(line, x, oy - 22, color, false);
    });
    r.changed.forEach((line, j) => {
      const inMiddle = j >= r.start && j < r.changed.length - r.end;
      const mj = j - r.start;
      let y;
      if (!trimmed) y = oy + (j + 0.5) * cell * (r.m / Math.max(1, r.changed.length));
      else if (j < r.start) y = oy - 4 - (r.start - j) * 18 + 4;
      else if (!inMiddle) y = oy + gridH + 18 + (j - (r.changed.length - r.end)) * 18;
      else y = py(mj);
      const color = trimmed && !inMiddle ? colors.trimmed : (stage >= 6 && r.inserted[mj] ? colors.insertedChip : colors.text);
      chip(line, trimmed && !inMiddle ? ox - 52 : ox - 30, y, color, false);
    });
    g.fillStyle = colors.muted; g.font = '12px system-ui, sans-serif';
    g.textAlign = 'left'; g.fillText('base →', ox, 14);
    g.save(); g.translate(14, oy); g.rotate(Math.PI / 2); g.fillText('changed →', 0, 0); g.restore();
    g.textAlign = 'center';
    if (stage < 2) return;

    // The grid and its free diagonals.
    g.strokeStyle = colors.grid; g.lineWidth = 1;
    for (let i = 0; i <= r.n; i++) { g.beginPath(); g.moveTo(px(i), py(0)); g.lineTo(px(i), py(r.m)); g.stroke(); }
    for (let j = 0; j <= r.m; j++) { g.beginPath(); g.moveTo(px(0), py(j)); g.lineTo(px(r.n), py(j)); g.stroke(); }
    g.setLineDash([3, 4]); g.strokeStyle = colors.diagonal;
    for (let i = 0; i < r.n; i++) for (let j = 0; j < r.m; j++) {
      if (r.a[i] === r.b[j]) { g.beginPath(); g.moveTo(px(i), py(j)); g.lineTo(px(i + 1), py(j + 1)); g.stroke(); }
    }
    g.setLineDash([]);

    // The search, round by round, up to the current frame.
    const seg = (p, q, color, w) => { g.strokeStyle = color; g.lineWidth = w; g.beginPath(); g.moveTo(px(p[0]), py(p[1])); g.lineTo(px(q[0]), py(q[1])); g.stroke(); };
    const dot = (p, color, r_) => { g.fillStyle = color; g.beginPath(); g.arc(px(p[0]), py(p[1]), r_, 0, Math.PI * 2); g.fill(); };
    if (stage >= 3) {
      r.rounds.forEach((steps, d) => {
        steps.forEach((s, idx) => {
          if (s.outside) return;
          const visible = stage > 3 || d < frame.round || (d === frame.round && idx <= frame.upto);
          if (!visible) return;
          const faded = stage >= 5;
          const color = faded ? '#d1d5db' : roundColor(d);
          if (d > 0) seg(s.from, s.mid, color, 2);
          if (s.mid[0] !== s.to[0]) seg(s.mid, s.to, color, 2);
          dot(s.to, color, faded ? 2.5 : 4);
          const current = stage === 3 && d === frame.round && idx === frame.upto;
          if (current) { g.strokeStyle = color; g.lineWidth = 2; g.beginPath(); g.arc(px(s.to[0]), py(s.to[1]), 9, 0, Math.PI * 2); g.stroke(); }
        });
      });
    }
    dot([0, 0], colors.text, 3);

    // The walk back, and the path that the hunks come from.
    if (stage >= 5) {
      const from = stage === 5 ? frame.upto : 0;
      for (let p = from; p < r.path.length; p++) {
        const s = r.path[p];
        if (s.from[0] !== s.mid[0] || s.from[1] !== s.mid[1]) seg(s.from, s.mid, colors.path, 4);
        if (s.mid[0] !== s.to[0]) seg(s.mid, s.to, colors.path, 4);
      }
      dot([r.n, r.m], colors.path, 5);
    }
  }

  function init() {
    if (!document.getElementById('lm-myers-style')) {
      const style = document.createElement('style');
      style.id = 'lm-myers-style'; style.textContent = css;
      document.head.appendChild(style);
    }
    document.querySelectorAll('.lm-myers').forEach(mount);
  }
  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
  }
  if (typeof module !== 'undefined') module.exports = { run };
})();
