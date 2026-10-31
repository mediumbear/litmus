// LitmusKit.flow: dataflow. Nodes and edges, laid out by dagre, with values that travel
// along the edges as packets, one step at a time. Nodes show the values they hold, and a
// node that drops or fails a value shows it.
//
//   <script src="assets/vendor/dagre.min.js"></script>
//   <script src="assets/kit/kit.js"></script>
//   <script src="assets/kit/flow.js"></script>
//   <script>
//   LitmusKit.flow('#token-flow', {
//     direction: 'LR',                                  // or 'TB'
//     nodes: [
//       { id: 'login', label: 'Sign in', kind: 'external' },
//       { id: 'service', label: 'TokenService' },
//       { id: 'keychain', label: 'Keychain', kind: 'store' },
//     ],
//     edges: [{ from: 'login', to: 'service', label: 'token' }, { from: 'service', to: 'keychain' }],
//     steps: [
//       { say: 'Sign in returns a token.', send: { from: 'login', to: 'service', value: 'abc…' } },
//       { say: 'The service writes it to the keychain.', send: { from: 'service', to: 'keychain', value: 'abc…' },
//         set: { keychain: 'abc…' }, code: 'KeychainStore.write 2..9' },
//       { say: 'Locked: the read fails, and nothing is lost.', fail: ['keychain'] },
//     ],
//   });
//   </script>
//
// A step's `send` is one packet or a list of them, each moving along its edge. `set`
// changes the values shown under nodes, and lasts. `fail`, `drop`, `good` and `flash` mark
// nodes for that step only. `code` lights lines of a listing on the page.
// Kinds: 'process' (the default, a box), 'store' (a cylinder), 'external' (a rounded pill),
// 'decision' (a diamond).

(function () {
  'use strict';
  const K = window.LitmusKit;
  if (!K) throw new Error('flow.js needs kit.js first');

  function path(points) {
    // A smooth curve through dagre's points.
    if (points.length < 3) return 'M' + points.map(function (p) { return p.x + ',' + p.y; }).join(' L');
    let d = 'M' + points[0].x + ',' + points[0].y;
    for (let i = 1; i < points.length - 1; i++) {
      const p = points[i], q = points[i + 1];
      const mx = (p.x + q.x) / 2, my = (p.y + q.y) / 2;
      d += ' Q' + p.x + ',' + p.y + ' ' + (i === points.length - 2 ? q.x + ',' + q.y : mx + ',' + my);
    }
    return d;
  }

  function shape(n, P) {
    const x = n.x - n.width / 2, y = n.y - n.height / 2, w = n.width, h = n.height;
    const base = { fill: P.box, stroke: P.line, 'stroke-width': '2' };
    if (n.kind === 'store') {
      const ry = 7;
      const body = K.svg('path', Object.assign({ d: 'M' + x + ',' + (y + ry) + ' a' + w / 2 + ',' + ry + ' 0 0 1 ' + w + ',0 v' + (h - 2 * ry) + ' a' + w / 2 + ',' + ry + ' 0 0 1 -' + w + ',0 z' }, base));
      const lid = K.svg('path', { d: 'M' + x + ',' + (y + ry) + ' a' + w / 2 + ',' + ry + ' 0 0 0 ' + w + ',0', fill: 'none', stroke: P.line, 'stroke-width': '2' });
      const g = K.svg('g', null, body, lid);
      g.paint = function (stroke, fill) { body.setAttribute('stroke', stroke); body.setAttribute('fill', fill); lid.setAttribute('stroke', stroke); };
      return g;
    }
    let e;
    if (n.kind === 'decision') {
      e = K.svg('polygon', Object.assign({ points: [n.x + ',' + y, (x + w) + ',' + n.y, n.x + ',' + (y + h), x + ',' + n.y].join(' ') }, base));
    } else {
      e = K.svg('rect', Object.assign({ x: x, y: y, width: w, height: h, rx: n.kind === 'external' ? h / 2 : 8 }, base));
    }
    e.paint = function (stroke, fill) { e.setAttribute('stroke', stroke); e.setAttribute('fill', fill); };
    return e;
  }

  K.flow = function (target, spec) {
    if (!window.dagre) throw new Error('LitmusKit.flow needs dagre.min.js before it');
    const root = K.mountPoint(target, 'flow');
    if (spec.title) root.append(K.el('div', 'lmk-title', null, spec.title));
    const P = K.palette;

    // Values each node shows, at each step.
    const initial = {};
    for (const n of spec.nodes) initial[n.id] = n.value || '';
    const values = K.states(initial, spec.steps, function (st, step) { Object.assign(st, step.set || {}); });

    // Layout. A node is as wide as its label or the longest value it ever shows.
    const g = new dagre.graphlib.Graph({ multigraph: true });
    g.setGraph({ rankdir: spec.direction || 'LR', nodesep: 34, ranksep: 70, marginx: 22, marginy: 30 });
    g.setDefaultEdgeLabel(function () { return {}; });
    for (const n of spec.nodes) {
      let w = K.textWidth(n.label, 14, 600) + 30;
      for (const st of values) w = Math.max(w, K.textWidth(st[n.id], 12) + 30);
      const h = n.kind === 'decision' ? 76 : 56;
      g.setNode(n.id, { width: Math.max(n.kind === 'decision' ? w * 1.4 : w, 96), height: h, kind: n.kind, label: n.label });
    }
    spec.edges.forEach(function (e, i) {
      const label = e.label ? { width: K.textWidth(e.label, 12) + 10, height: 16, labelpos: 'c' } : {};
      g.setEdge(e.from, e.to, Object.assign({ label: e.label }, label), 'e' + i);
    });
    dagre.layout(g);
    const graph = g.graph();

    const s = K.svg('svg', { viewBox: '0 0 ' + Math.ceil(graph.width) + ' ' + Math.ceil(graph.height), role: 'img', 'aria-label': spec.title || 'dataflow' });
    s.append(K.svg('defs', null, K.svg('marker', { id: 'lmk-flow-arrow', viewBox: '0 0 10 10', refX: '9', refY: '5', markerWidth: '7', markerHeight: '7', orient: 'auto-start-reverse' },
      K.svg('path', { d: 'M0,0 L10,5 L0,10 z', fill: 'context-stroke' }))));
    const edgeLayer = K.svg('g'), nodeLayer = K.svg('g'), packetLayer = K.svg('g');
    s.append(edgeLayer, nodeLayer, packetLayer);

    // Edges, found again by 'from>to' for the packets.
    const edges = {};
    spec.edges.forEach(function (e, i) {
      const lay = g.edge({ v: e.from, w: e.to, name: 'e' + i });
      const p = K.svg('path', { d: path(lay.points), fill: 'none', stroke: P.line, 'stroke-width': '2', 'marker-end': 'url(#lmk-flow-arrow)' });
      edgeLayer.append(p);
      if (e.label) {
        edgeLayer.append(K.svg('rect', { x: lay.x - lay.width / 2, y: lay.y - 9, width: lay.width, height: 18, rx: '4', fill: '#f8fafc' }));
        edgeLayer.append(K.svg('text', { x: lay.x, y: lay.y + 4, 'text-anchor': 'middle', 'font-size': '12', fill: P.muted }, e.label));
      }
      edges[e.from + '>' + e.to] = edges[e.from + '>' + e.to] || p;
    });

    // Nodes: a shape, a label, the value it holds, and a mark for a value dropped or failed.
    const nodes = {};
    for (const n of spec.nodes) {
      const lay = g.node(n.id);
      const sh = shape(lay, P);
      const label = K.svg('text', { x: lay.x, y: lay.y - (n.kind === 'store' ? 0 : 4), 'text-anchor': 'middle', 'font-size': '14', 'font-weight': '600', fill: P.ink }, n.label);
      const value = K.svg('text', { x: lay.x, y: lay.y + 16, 'text-anchor': 'middle', 'font-size': '12', fill: P.muted }, '');
      const mark = K.svg('text', { x: lay.x + lay.width / 2 - 4, y: lay.y - lay.height / 2 + 2, 'text-anchor': 'middle', 'font-size': '18', 'font-weight': '700' }, '');
      nodeLayer.append(K.svg('g', null, sh, label, value, mark));
      nodes[n.id] = { shape: sh, value: value, mark: mark };
    }

    root.append(K.el('div', 'lmk-stage', null, s));

    // A packet: a pill with its value, moved along an edge's path.
    let running = [];
    function packet(edge, text, animate) {
      const w = Math.max(30, K.textWidth(text, 12, 700) + 16);
      const pill = K.svg('rect', { x: -w / 2, y: '-10', width: w, height: '20', rx: '10', fill: P.token, stroke: '#b45309', 'stroke-width': '1.5' });
      const t = K.svg('text', { x: '0', y: '4', 'text-anchor': 'middle', 'font-size': '12', 'font-weight': '700', fill: '#451a03' }, text);
      const grp = K.svg('g', null, pill, t);
      packetLayer.append(grp);
      const length = edge.getTotalLength();
      function place(f) {
        const pt = edge.getPointAtLength(length * f);
        grp.setAttribute('transform', 'translate(' + pt.x + ',' + pt.y + ')');
      }
      if (!animate) { place(1); return; }
      place(0);
      running.push(K.animate(900, place));
    }

    function show(i, how) {
      const step = spec.steps[i], st = values[i];
      running.forEach(function (stop) { stop(); });
      running = [];
      packetLayer.innerHTML = '';
      const sends = step.send ? [].concat(step.send) : [];
      const tone = {};
      for (const sd of sends) tone[sd.from] = tone[sd.to] = 'active';
      for (const id of step.flash || []) tone[id] = 'flash';
      for (const id of step.good || []) tone[id] = 'good';
      for (const id of step.drop || []) tone[id] = 'drop';
      for (const id of step.fail || []) tone[id] = 'bad';
      for (const id in nodes) {
        const n = nodes[id], t = tone[id];
        n.shape.paint(t === 'good' ? P.good : t === 'bad' ? P.bad : t === 'flash' ? P.warn : t === 'active' ? P.active : t === 'drop' ? P.muted : P.line,
          t === 'good' ? P.goodFill : t === 'bad' ? P.badFill : t === 'flash' ? P.warnFill : t === 'active' ? P.activeFill : t === 'drop' ? '#f1f5f9' : P.box);
        n.value.textContent = st[id] || '';
        n.value.setAttribute('fill', st[id] !== initial[id] ? P.ink : P.muted);
        n.mark.textContent = t === 'bad' ? '✕' : t === 'drop' ? '∅' : t === 'good' ? '✓' : '';
        n.mark.setAttribute('fill', t === 'bad' ? P.bad : t === 'good' ? P.good : P.muted);
      }
      for (const key in edges) {
        const on = sends.some(function (sd) { return sd.from + '>' + sd.to === key; });
        edges[key].setAttribute('stroke', on ? P.active : P.line);
        edges[key].setAttribute('stroke-width', on ? '3' : '2');
      }
      for (const sd of sends) {
        const edge = edges[sd.from + '>' + sd.to];
        if (edge && sd.value != null) packet(edge, String(sd.value), how === 'step');
      }
      return step;
    }

    return K.player(root, { count: spec.steps.length, show: show, speed: spec.speed || 2000 });
  };
})();
