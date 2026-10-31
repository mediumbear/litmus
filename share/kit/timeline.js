// LitmusKit.timeline: events along a scrubbable axis, a band that shows the state of the
// world at each event, and lanes that show, for each event, whether something works there.
// The reader scrubs or steps through the events, and picks the lane to focus on.
//
//   LitmusKit.timeline('#lock-day', {
//     title: 'A day in the life of the lock',
//     states: { BFU: { label: 'Before first unlock', color: '#7c3aed' },
//               AFU: { label: 'Locked', color: '#64748b' }, OPEN: { label: 'Unlocked', color: '#0ea5e9' } },
//     events: [
//       { title: 'Power on', state: 'BFU', say: 'Nobody has entered the passcode yet.' },
//       { title: 'Silent push', state: 'AFU', say: 'The app wakes in the background.', code: 'AppDelegate.didReceive 4..9' },
//     ],
//     lanes: [
//       { id: 'when', label: 'WhenUnlocked', values: ['idle', 'fail'] },
//       { id: 'after', label: 'AfterFirstUnlock (chosen)', values: ['idle', 'ok'] },
//     ],
//     focus: 'after',
//   });
//
// A lane's value at an event is 'ok', 'fail', 'idle' (nothing is asked of it), or 'warn'.
// The narration gives the event, what it says, and the focused lane's value there.

(function () {
  'use strict';
  const K = window.LitmusKit;
  if (!K) throw new Error('timeline.js needs kit.js first');

  K.addStyle('lmk-timeline-style', `
.lmk-timeline canvas { display: block; width: 100%; cursor: pointer; touch-action: none; }
.lmk-timeline .lmk-verdict { font-weight: 600; }
`);

  const WORDS = { ok: 'works', fail: 'fails', warn: 'works, with a catch', idle: 'is not asked' };

  K.timeline = function (target, spec) {
    const root = K.mountPoint(target, 'timeline');
    if (spec.title) root.append(K.el('div', 'lmk-title', null, spec.title));
    const P = K.palette;
    const events = spec.events, lanes = spec.lanes;
    let focus = spec.focus || (lanes[0] && lanes[0].id);
    let current = 0;

    if (lanes.length > 1) {
      const pick = K.el('div', 'lmk-row', null, 'Focus on:');
      const buttons = lanes.map(function (lane) {
        const b = K.el('button', lane.id === focus ? 'on' : null, { type: 'button' }, lane.short || lane.label);
        b.onclick = function () {
          focus = lane.id;
          buttons.forEach(function (x) { x.classList.toggle('on', x === b); });
          player.redraw();
        };
        return b;
      });
      pick.append.apply(pick, buttons);
      root.append(pick);
    }

    const canvas = K.el('canvas');
    root.append(K.el('div', 'lmk-stage', null, canvas));
    const ctx = canvas.getContext('2d');
    const BAND = 30, ROW = 34, LEFT_MIN = 120, TOP = 8;

    function value(lane, i) {
      return typeof lane.value === 'function' ? lane.value(events[i], i) : (lane.values || [])[i] || 'idle';
    }

    // Geometry for the canvas's current width.
    function layout() {
      const width = canvas.clientWidth || 600;
      let left = LEFT_MIN;
      for (const lane of lanes) left = Math.max(left, K.textWidth(lane.short || lane.label, 13, 600) + 22);
      left = Math.min(left, width * .4);
      const height = TOP + BAND + 10 + lanes.length * ROW + 30;
      const step = (width - left - 20) / Math.max(events.length - 1, 1);
      return { width: width, height: height, left: left, step: step, x: function (i) { return left + 10 + i * step; } };
    }

    function draw() {
      const L = layout(), dpr = window.devicePixelRatio || 1;
      canvas.width = Math.round(L.width * dpr);
      canvas.height = Math.round(L.height * dpr);
      canvas.style.height = L.height + 'px';
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, L.width, L.height);
      ctx.font = '600 13px system-ui, sans-serif';
      ctx.textBaseline = 'middle';

      // The band: one stretch of colour per event, the current one stronger.
      for (let i = 0; i < events.length; i++) {
        const st = (spec.states || {})[events[i].state] || { color: '#94a3b8' };
        const x0 = i === 0 ? L.left : (L.x(i - 1) + L.x(i)) / 2, x1 = i === events.length - 1 ? L.width - 4 : (L.x(i) + L.x(i + 1)) / 2;
        ctx.globalAlpha = i === current ? 1 : .45;
        ctx.fillStyle = st.color;
        ctx.fillRect(x0, TOP, x1 - x0, BAND);
      }
      ctx.globalAlpha = 1;
      const now = (spec.states || {})[events[current].state];
      ctx.fillStyle = P.ink;
      ctx.fillText(now ? now.label : '', 8, TOP + BAND / 2);

      // The current event's column.
      const c0 = Math.max(L.left, L.x(current) - L.step / 2), c1 = Math.min(L.width, L.x(current) + L.step / 2);
      ctx.fillStyle = 'rgba(37, 99, 235, .08)';
      ctx.fillRect(c0, TOP + BAND, c1 - c0, L.height - TOP - BAND - 22);

      // Lanes.
      lanes.forEach(function (lane, r) {
        const y = TOP + BAND + 10 + r * ROW + ROW / 2;
        if (lane.id === focus) {
          ctx.fillStyle = '#eef2ff';
          ctx.fillRect(0, y - ROW / 2 + 2, L.width, ROW - 4);
        }
        ctx.fillStyle = lane.id === focus ? P.ink : P.muted;
        ctx.font = (lane.id === focus ? '600 ' : '400 ') + '13px system-ui, sans-serif';
        ctx.fillText(lane.short || lane.label, 8, y);
        ctx.strokeStyle = P.line;
        ctx.beginPath(); ctx.moveTo(L.left, y); ctx.lineTo(L.width - 6, y); ctx.stroke();
        for (let i = 0; i < events.length; i++) {
          const v = value(lane, i);
          const radius = v === 'idle' ? 3.5 : (i === current ? 9 : 7);
          ctx.fillStyle = v === 'ok' ? P.good : v === 'fail' ? P.bad : v === 'warn' ? P.warn : P.line;
          ctx.beginPath(); ctx.arc(L.x(i), y, radius, 0, Math.PI * 2); ctx.fill();
        }
      });

      // The event's title under the lanes.
      ctx.fillStyle = P.ink;
      ctx.font = '600 12px system-ui, sans-serif';
      const title = events[current].title;
      const tw = ctx.measureText(title).width;
      ctx.fillText(title, Math.max(4, Math.min(L.width - tw - 4, L.x(current) - tw / 2)), L.height - 12);
    }

    // Scrubbing: the event nearest the pointer.
    function pick(e) {
      const L = layout(), box = canvas.getBoundingClientRect();
      const x = e.clientX - box.left;
      const i = Math.round((x - L.left - 10) / L.step);
      player.stop();
      player.go(Math.max(0, Math.min(events.length - 1, i)), 'jump');
    }
    let dragging = false;
    canvas.addEventListener('pointerdown', function (e) { dragging = true; canvas.setPointerCapture(e.pointerId); pick(e); });
    canvas.addEventListener('pointermove', function (e) { if (dragging) pick(e); });
    canvas.addEventListener('pointerup', function () { dragging = false; });
    window.addEventListener('resize', draw);

    function show(i) {
      current = i;
      draw();
      const ev = events[i];
      const lane = lanes.find(function (l) { return l.id === focus; });
      let text = '<b>' + ev.title + '.</b> ' + (ev.say || '');
      if (lane) {
        const v = value(lane, i);
        const words = (lane.words || {})[v] || WORDS[v] || v;
        text += ' <span class="lmk-verdict" style="color:' + (v === 'ok' ? P.good : v === 'fail' ? P.bad : v === 'warn' ? P.warn : P.muted) + '">' + (lane.short || lane.label) + ' ' + words + '.</span>';
        if (lane.note && v !== 'idle') text += ' ' + lane.note;
      }
      return { say: text, code: ev.code };
    }

    const player = K.player(root, { count: events.length, show: show, speed: spec.speed || 1600 });
    return player;
  };
})();
