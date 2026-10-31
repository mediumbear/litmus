// The Litmus widget kit: the parts every widget shares. A widget is mounted from a
// passthrough block of a document:
//
//   <div id="read-path"></div>
//   <script src="assets/kit/kit.js"></script>
//   <script src="assets/kit/stepper.js"></script>
//   <script>LitmusKit.stepper('#read-path', { ... });</script>
//
// Everything here is a classic script, so a page opens from file:// with no server.
// The player is the step engine: Back / Play / Step, a scrubber, the arrow keys, and one
// sentence of narration per step. A step may name lines of a listing on the page, as
// code: 'KeychainStore.write 3..7', and the weave's LitmusLines lights them (V5).

(function () {
  'use strict';
  if (window.LitmusKit) return;

  const css = `
.lmk { margin: 1.25em 0; border: 1px solid #e5e7eb; border-radius: 10px; padding: 14px; background: #fcfcfd;
  font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; color: #1f2937; max-width: 100%; box-sizing: border-box; }
.lmk:focus { outline: 2px solid #c7d2fe; outline-offset: 2px; }
.lmk-title { font-weight: 600; margin-bottom: .4em; color: #0f172a; }
.lmk-stage { position: relative; width: 100%; overflow: hidden; border-radius: 8px; background: #f8fafc; }
.lmk-stage svg { display: block; width: 100%; height: auto; }
.lmk-row { display: flex; flex-wrap: wrap; gap: .4em; align-items: center; margin: .55em 0; font-size: .9em; }
.lmk button { font: inherit; font-size: .9em; padding: .3em .8em; border: 1px solid #cbd5e1; border-radius: 6px; background: white;
  color: #0f172a; cursor: pointer; touch-action: manipulation; }
.lmk button:hover:not(:disabled) { background: #f1f5f9; }
.lmk button:disabled { opacity: .35; cursor: default; }
.lmk button.on { background: #0f172a; color: white; border-color: #0f172a; }
.lmk button.lmk-play { min-width: 5.2em; }
.lmk input[type=range] { flex: 1; min-width: 120px; accent-color: #2563eb; }
.lmk-count { color: #64748b; font-variant-numeric: tabular-nums; margin-left: auto; }
.lmk-say { min-height: 3em; line-height: 1.5; padding: .5em .7em; border-left: 3px solid #2563eb; background: white; border-radius: 0 6px 6px 0; }
.lmk-say code { font-size: .92em; background: #f1f5f9; padding: 0 .25em; border-radius: 3px; }
.lmk-hint { font-size: .78em; color: #94a3b8; margin-top: .3em; }
`;

  function addStyle(id, text) {
    if (document.getElementById(id)) return;
    const s = document.createElement('style');
    s.id = id;
    s.textContent = text;
    document.head.appendChild(s);
  }
  addStyle('lmk-style', css);

  // An element with a class, attributes and children: el('button', 'on', { type: 'button' }, 'Play').
  function el(tag, cls, attrs, ...children) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    for (const k in attrs || {}) e.setAttribute(k, attrs[k]);
    for (const c of children) if (c != null) e.append(c);
    return e;
  }

  const SVG = 'http://www.w3.org/2000/svg';
  function svg(tag, attrs, ...children) {
    const e = document.createElementNS(SVG, tag);
    for (const k in attrs || {}) e.setAttribute(k, attrs[k]);
    for (const c of children) if (c != null) e.append(c);
    return e;
  }

  // The element a widget mounts in: a selector or an element. The widget's frame is put in it.
  function mountPoint(target, kind) {
    const host = typeof target === 'string' ? document.querySelector(target) : target;
    if (!host) throw new Error('LitmusKit.' + kind + ': nothing matches ' + target);
    host.innerHTML = '';
    const root = el('div', 'lmk lmk-' + kind, { tabindex: '0' });
    host.appendChild(root);
    return root;
  }

  // A step's `code`: "NAME RANGES", where NAME may hold spaces ("FILE NAME").
  function lightCode(code) {
    if (!window.LitmusLines) return false;
    if (!code) return false;
    const at = code.lastIndexOf(' ');
    if (at < 0) return !!window.LitmusLines.light(code, '');
    return !!window.LitmusLines.light(code.slice(0, at), code.slice(at + 1));
  }

  // The step engine. `count` steps, numbered from 0; `show(i, how)` draws step i, where how is
  // 'step' when the reader moved one step forward (animate), and 'jump' otherwise (draw at
  // once). It returns { say, code } for the narration and the lines to light.
  function player(root, options) {
    const count = options.count;
    const speed = options.speed || 1800;
    let at = 0, timer = null, lit = false;

    const say = el('div', 'lmk-say', { 'aria-live': 'polite' });
    const back = el('button', null, { type: 'button', title: 'Back (←)' }, '◀ Back');
    const play = el('button', 'lmk-play', { type: 'button', title: 'Play (space)' }, '▶ Play');
    const step = el('button', null, { type: 'button', title: 'Step (→)' }, 'Step ▶');
    const scrub = el('input', null, { type: 'range', min: '0', max: String(Math.max(count - 1, 0)), value: '0', 'aria-label': 'Step' });
    const counter = el('span', 'lmk-count');
    const controls = el('div', 'lmk-row', null, back, play, step, scrub, counter);
    root.append(controls, say);
    if (options.hint !== false) root.append(el('div', 'lmk-hint', null, '← → step · space plays · drag the slider to scrub'));

    function draw(how) {
      const r = options.show(at, how) || {};
      say.innerHTML = r.say || '';
      if (r.code) {
        lit = lightCode(r.code) || lit;
      } else if (lit && window.LitmusLines) {
        window.LitmusLines.clear();
        lit = false;
      }
      back.disabled = at === 0;
      step.disabled = at >= count - 1;
      scrub.value = String(at);
      counter.textContent = (at + 1) + ' / ' + count;
    }
    function go(i, how) {
      at = Math.max(0, Math.min(count - 1, i));
      draw(how);
    }
    function stop() {
      if (timer) clearInterval(timer);
      timer = null;
      play.textContent = '▶ Play';
      play.classList.remove('on');
    }
    function start() {
      if (at >= count - 1) go(0, 'jump');
      play.textContent = '❚❚ Pause';
      play.classList.add('on');
      timer = setInterval(function () {
        if (at >= count - 1) return stop();
        go(at + 1, 'step');
      }, speed);
    }
    back.onclick = function () { stop(); go(at - 1, 'jump'); };
    step.onclick = function () { stop(); go(at + 1, 'step'); };
    play.onclick = function () { timer ? stop() : start(); };
    scrub.oninput = function () { stop(); go(parseInt(scrub.value, 10), 'jump'); };
    root.addEventListener('keydown', function (e) {
      if (e.target.tagName === 'INPUT' && e.target.type !== 'range') return;
      if (e.key === 'ArrowRight') { stop(); go(at + 1, 'step'); e.preventDefault(); }
      else if (e.key === 'ArrowLeft') { stop(); go(at - 1, 'jump'); e.preventDefault(); }
      else if (e.key === ' ' && e.target === root) { timer ? stop() : start(); e.preventDefault(); }
    });
    // The page may still be laying out its listings; draw again when it is done.
    go(0, 'jump');
    window.addEventListener('load', function () { draw('jump'); });
    return { go: go, stop: stop, get at() { return at; }, redraw: function () { draw('jump'); } };
  }

  // The state at each step, from an initial state and each step's changes, so that Back and
  // the scrubber can draw any step at once.
  function states(initial, steps, apply) {
    const out = [];
    let s = JSON.parse(JSON.stringify(initial || {}));
    for (const step of steps) {
      s = JSON.parse(JSON.stringify(s));
      apply(s, step);
      out.push(s);
    }
    return out;
  }

  // Measures text in the page's font, for laying out boxes before they are drawn.
  const measurer = document.createElement('canvas').getContext('2d');
  function textWidth(text, size, weight) {
    measurer.font = (weight || 400) + ' ' + (size || 14) + 'px system-ui, -apple-system, "Segoe UI", sans-serif';
    return measurer.measureText(String(text)).width;
  }

  // Eases a value from 0 to 1 over `ms`, calling `frame(t)`; returns a function that stops it.
  function animate(ms, frame, done) {
    let stopped = false;
    const t0 = performance.now();
    function tick(now) {
      if (stopped) return;
      const t = Math.min(1, (now - t0) / ms);
      frame(t < .5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);
      if (t < 1) requestAnimationFrame(tick); else if (done) done();
    }
    requestAnimationFrame(tick);
    return function () { stopped = true; };
  }

  const palette = {
    ink: '#0f172a', muted: '#64748b', line: '#cbd5e1', box: '#ffffff', active: '#2563eb', activeFill: '#eff6ff',
    good: '#16a34a', goodFill: '#dcfce7', bad: '#dc2626', badFill: '#fee2e2', warn: '#ca8a04', warnFill: '#fef9c3', token: '#f59e0b',
  };

  window.LitmusKit = { el, svg, mountPoint, player, states, textWidth, animate, addStyle, lightCode, palette };
})();
