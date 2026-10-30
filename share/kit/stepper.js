// LitmusKit.stepper: boxes, arrows between them, and a token that moves from box to box,
// one step at a time, with a sentence of narration for each step.
//
//   LitmusKit.stepper('#read-path', {
//     title: 'Reading the token',                      // optional
//     boxes: [                                         // col and row place a box; by default in a row
//       { id: 'cache', label: 'Memory cache', value: 'empty' },
//       { id: 'keychain', label: 'Keychain', col: 1 },
//     ],
//     arrows: [{ from: 'cache', to: 'keychain', label: 'miss' }],
//     token: 'read',                                   // the token's label; none if left out
//     steps: [
//       { say: 'The read starts at the cache.', at: 'cache', code: 'TokenService.value 3..4' },
//       { say: 'It is empty, so the read goes on.', at: 'keychain', set: { cache: 'empty' }, arrow: 'cache>keychain' },
//       { say: 'The keychain answers.', set: { keychain: 'token' }, good: ['keychain'], token: 'token' },
//     ],
//   });
//
// A step's `set` changes the values shown in boxes and lasts until changed again; `at`
// moves the token; `good`, `bad` and `flash` colour boxes for that step only; `arrow`
// lights an arrow, as 'from>to'; `token` relabels the token; `code` lights lines of a listing.

(function () {
  'use strict';
  const K = window.LitmusKit;
  if (!K) throw new Error('stepper.js needs kit.js first');

  K.stepper = function (target, spec) {
    const root = K.mountPoint(target, 'stepper');
    if (spec.title) root.append(K.el('div', 'lmk-title', null, spec.title));
    const P = K.palette;
    const boxes = spec.boxes.map(function (b, i) {
      return Object.assign({ col: b.col != null ? b.col : (b.row != null ? 0 : i), row: b.row || 0 }, b);
    });
    const byId = {};
    boxes.forEach(function (b) { byId[b.id] = b; });

    // Every cell is as wide as the widest box needs.
    let widest = 110;
    for (const b of boxes) widest = Math.max(widest, K.textWidth(b.label, 14, 600) + 28);
    for (const s of spec.steps) for (const k in s.set || {}) widest = Math.max(widest, K.textWidth(s.set[k], 13) + 28);
    const W = Math.min(widest, 240), H = 64, GX = 70, GY = 46, PAD = 24, TOP = 34;
    const cols = Math.max.apply(null, boxes.map(function (b) { return b.col; })) + 1;
    const rows = Math.max.apply(null, boxes.map(function (b) { return b.row; })) + 1;
    const width = PAD * 2 + cols * W + (cols - 1) * GX;
    const height = TOP + PAD + rows * H + (rows - 1) * GY;
    for (const b of boxes) {
      b.x = PAD + b.col * (W + GX);
      b.y = TOP + b.row * (H + GY);
    }

    const s = K.svg('svg', { viewBox: '0 0 ' + width + ' ' + height, role: 'img', 'aria-label': spec.title || 'step-through' });
    s.append(K.svg('defs', null, K.svg('marker', { id: 'lmk-arrow', viewBox: '0 0 10 10', refX: '9', refY: '5', markerWidth: '7', markerHeight: '7', orient: 'auto-start-reverse' },
      K.svg('path', { d: 'M0,0 L10,5 L0,10 z', fill: 'context-stroke' }))));

    // Arrows from the edge of one box to the edge of the other.
    const arrows = {};
    for (const a of spec.arrows || []) {
      const f = byId[a.from], t = byId[a.to];
      const fx = f.x + W / 2, fy = f.y + H / 2, tx = t.x + W / 2, ty = t.y + H / 2;
      const dx = tx - fx, dy = ty - fy;
      const k = Math.min(Math.abs(dx) > 0 ? (W / 2 + 4) / Math.abs(dx) : 1e9, Math.abs(dy) > 0 ? (H / 2 + 4) / Math.abs(dy) : 1e9);
      const x1 = fx + dx * k, y1 = fy + dy * k, x2 = tx - dx * k, y2 = ty - dy * k;
      const line = K.svg('line', { x1: x1, y1: y1, x2: x2, y2: y2, stroke: P.line, 'stroke-width': '2', 'marker-end': 'url(#lmk-arrow)' });
      const g = K.svg('g', null, line);
      if (a.label) {
        const lx = (x1 + x2) / 2, ly = (y1 + y2) / 2 - 7;
        g.append(K.svg('text', { x: lx, y: ly, 'text-anchor': 'middle', 'font-size': '12', fill: P.muted }, a.label));
      }
      s.append(g);
      arrows[a.from + '>' + a.to] = line;
    }

    // Boxes: a label, and a value under it.
    for (const b of boxes) {
      b.rect = K.svg('rect', { x: b.x, y: b.y, width: W, height: H, rx: '9', fill: P.box, stroke: P.line, 'stroke-width': '2' });
      b.labelText = K.svg('text', { x: b.x + W / 2, y: b.y + 25, 'text-anchor': 'middle', 'font-size': '14', 'font-weight': '600', fill: P.ink }, b.label);
      b.valueText = K.svg('text', { x: b.x + W / 2, y: b.y + 46, 'text-anchor': 'middle', 'font-size': '13', fill: P.muted }, '');
      s.append(K.svg('g', null, b.rect, b.labelText, b.valueText));
    }

    // The token, a pill above the box it is at.
    let token = null, tokenText = null, tokenAt = null, stopMove = null;
    if (spec.token != null) {
      tokenText = K.svg('text', { x: '0', y: '4', 'text-anchor': 'middle', 'font-size': '12', 'font-weight': '700', fill: '#451a03' }, spec.token);
      const pill = K.svg('rect', { x: '-30', y: '-11', width: '60', height: '22', rx: '11', fill: P.token, stroke: '#b45309', 'stroke-width': '1.5' });
      token = K.svg('g', { opacity: '0' }, pill, tokenText);
      token.pill = pill;
      s.append(token);
    }
    function tokenPlace(id) {
      const b = byId[id];
      return { x: b.x + W / 2, y: b.y - 13 };
    }
    function setToken(label) {
      tokenText.textContent = label;
      const w = Math.max(44, K.textWidth(label, 12, 700) + 20);
      token.pill.setAttribute('x', -w / 2);
      token.pill.setAttribute('width', w);
    }

    const stage = K.el('div', 'lmk-stage', null, s);
    root.append(stage);

    const initial = {};
    for (const b of boxes) initial[b.id] = b.value || '';
    const valueStates = K.states(initial, spec.steps, function (st, step) { Object.assign(st, step.set || {}); });
    // Where the token is, and its label, at each step: it stays until moved.
    const places = [], labels = [];
    let where = null, label = spec.token;
    for (const step of spec.steps) {
      if (step.at !== undefined) where = step.at;
      if (step.token != null) label = step.token;
      places.push(where);
      labels.push(label);
    }

    function show(i, how) {
      const step = spec.steps[i], values = valueStates[i];
      const tone = {};
      for (const id of step.flash || []) tone[id] = 'flash';
      for (const id of step.good || []) tone[id] = 'good';
      for (const id of step.bad || []) tone[id] = 'bad';
      if (places[i] && !tone[places[i]]) tone[places[i]] = 'active';
      for (const b of boxes) {
        const t = tone[b.id];
        b.rect.setAttribute('stroke', t === 'good' ? P.good : t === 'bad' ? P.bad : t === 'flash' ? P.warn : t === 'active' ? P.active : P.line);
        b.rect.setAttribute('fill', t === 'good' ? P.goodFill : t === 'bad' ? P.badFill : t === 'flash' ? P.warnFill : t === 'active' ? P.activeFill : P.box);
        b.valueText.textContent = values[b.id] || '';
        b.valueText.setAttribute('fill', values[b.id] !== initial[b.id] ? P.ink : P.muted);
      }
      for (const key in arrows) {
        const on = step.arrow === key;
        arrows[key].setAttribute('stroke', on ? P.active : P.line);
        arrows[key].setAttribute('stroke-width', on ? '3' : '2');
      }
      if (token) {
        if (stopMove) stopMove();
        const place = places[i];
        setToken(labels[i] == null ? '' : String(labels[i]));
        if (!place) {
          token.setAttribute('opacity', '0');
          tokenAt = null;
        } else {
          const to = tokenPlace(place);
          const from = tokenAt && how === 'step' ? tokenPlace(tokenAt) : to;
          token.setAttribute('opacity', '1');
          stopMove = K.animate(how === 'step' ? 550 : 1, function (t) {
            const x = from.x + (to.x - from.x) * t;
            const y = from.y + (to.y - from.y) * t - Math.sin(Math.PI * t) * (from.x === to.x && from.y === to.y ? 0 : 24);
            token.setAttribute('transform', 'translate(' + x + ',' + y + ')');
          });
          tokenAt = place;
        }
      }
      return step;
    }

    return K.player(root, { count: spec.steps.length, show: show, speed: spec.speed });
  };
})();
