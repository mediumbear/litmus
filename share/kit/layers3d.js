// LitmusKit.layers3d: a stack of plates in 3D, and a token that falls through them one
// step at a time, stopping at the layer that answers. Drag to turn the stack.
// Needs three.js r147 and its classic OrbitControls, which run from file://:
//
//   <script src="assets/vendor/three.min.js"></script>
//   <script src="assets/vendor/OrbitControls.js"></script>
//   <script src="assets/kit/kit.js"></script>
//   <script src="assets/kit/layers3d.js"></script>
//   <script>
//   LitmusKit.layers3d('#read-stack', {
//     layers: [
//       { id: 'cache', label: 'Memory cache', color: '#38bdf8' },
//       { id: 'keychain', label: 'Keychain', color: '#22c55e' },
//       { id: 'result', label: 'authToken returns', color: '#94a3b8' },
//     ],
//     token: 'read',
//     steps: [
//       { say: 'The read starts above the stack.', at: null },
//       { say: 'The cache is empty: the read falls through.', at: 'cache', pass: true },
//       { say: 'The keychain answers.', at: 'keychain', token: 'token', good: true, code: 'KeychainStore.read 5..12' },
//     ],
//   });
//   </script>
//
// A step's `at` is the layer the token is at (null: above the stack); `pass` shows the
// layer letting it through, `good` and `bad` colour the answer.

(function () {
  'use strict';
  const K = window.LitmusKit;
  if (!K) throw new Error('layers3d.js needs kit.js first');

  // A label as a sprite, drawn on a canvas.
  function label(text, colour) {
    const c = document.createElement('canvas'), ctx = c.getContext('2d');
    const size = 48;
    ctx.font = '600 ' + size + 'px system-ui, sans-serif';
    c.width = Math.ceil(ctx.measureText(text).width) + 40;
    c.height = size + 24;
    ctx.font = '600 ' + size + 'px system-ui, sans-serif';
    ctx.fillStyle = colour || '#0f172a';
    ctx.textBaseline = 'middle';
    ctx.fillText(text, 20, c.height / 2);
    const tex = new THREE.CanvasTexture(c);
    const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, depthTest: false }));
    const h = .45;
    sprite.scale.set(h * c.width / c.height, h, 1);
    sprite.userData.canvas = c;
    return sprite;
  }

  K.layers3d = function (target, spec) {
    if (!window.THREE || !THREE.OrbitControls) throw new Error('LitmusKit.layers3d needs three.min.js and OrbitControls.js (r147) before it');
    const root = K.mountPoint(target, 'layers3d');
    if (spec.title) root.append(K.el('div', 'lmk-title', null, spec.title));
    const P = K.palette;
    const stage = K.el('div', 'lmk-stage', { style: 'height:360px;cursor:grab;background:linear-gradient(#f8fafc,#e2e8f0)' });
    stage.append(K.el('div', 'lmk-hint', { style: 'position:absolute;right:10px;bottom:6px;margin:0' }, 'drag to turn'));
    root.append(stage);

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(40, 1, .1, 100);
    camera.position.set(6.5, 4.5, 7.5);
    const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setPixelRatio(window.devicePixelRatio || 1);
    stage.prepend(renderer.domElement);
    renderer.domElement.style.display = 'block';
    scene.add(new THREE.AmbientLight(0xffffff, .65));
    const sun = new THREE.DirectionalLight(0xffffff, .8);
    sun.position.set(4, 8, 5);
    scene.add(sun);

    const GAP = 1.4, n = spec.layers.length, top = (n - 1) * GAP / 2;
    const plates = {};
    spec.layers.forEach(function (layer, i) {
      const y = top - i * GAP;
      const mat = new THREE.MeshStandardMaterial({ color: layer.color || '#94a3b8', transparent: true, opacity: .55, roughness: .6 });
      const mesh = new THREE.Mesh(new THREE.BoxGeometry(4, .16, 2.6), mat);
      mesh.position.y = y;
      scene.add(mesh);
      const edges = new THREE.LineSegments(new THREE.EdgesGeometry(mesh.geometry), new THREE.LineBasicMaterial({ color: 0x334155 }));
      mesh.add(edges);
      const tag = label(layer.label);
      tag.position.set(-2.1 - tag.scale.x / 2, y, 1.3);
      scene.add(tag);
      plates[layer.id] = { mesh: mesh, y: y, base: new THREE.Color(layer.color || '#94a3b8') };
    });

    const ball = new THREE.Mesh(new THREE.SphereGeometry(.26, 32, 16), new THREE.MeshStandardMaterial({ color: P.token, roughness: .4 }));
    scene.add(ball);
    let ballTag = null;
    function tokenLabel(text) {
      if (ballTag) ball.remove(ballTag);
      ballTag = text ? label(text, '#78350f') : null;
      if (ballTag) { ballTag.position.set(0, .55, 0); ball.add(ballTag); }
    }

    const controls = new THREE.OrbitControls(camera, renderer.domElement);
    controls.enableZoom = false;
    controls.enablePan = false;
    controls.target.set(0, 0, 0);

    function size() {
      const w = stage.clientWidth || 600, h = stage.clientHeight || 360;
      renderer.setSize(w, h, false);
      renderer.domElement.style.width = '100%';
      renderer.domElement.style.height = h + 'px';
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
    }
    size();
    window.addEventListener('resize', size);
    (function loop() { controls.update(); renderer.render(scene, camera); requestAnimationFrame(loop); })();

    // Where the token is, and its label, at each step.
    const places = [], labels = [];
    let where = null, text = spec.token || '';
    for (const step of spec.steps) {
      if (step.at !== undefined) where = step.at;
      if (step.token != null) text = step.token;
      places.push(where);
      labels.push(text);
    }
    function yOf(id) { return id && plates[id] ? plates[id].y + .42 : top + 1.4; }
    let stopFall = null, lastY = yOf(null);

    function show(i, how) {
      const step = spec.steps[i];
      for (const id in plates) {
        const p = plates[id], on = id === places[i];
        const colour = on && step.good ? new THREE.Color(P.good) : on && step.bad ? new THREE.Color(P.bad) : p.base;
        p.mesh.material.color.copy(colour);
        p.mesh.material.opacity = on ? (step.pass ? .3 : .9) : .45;
      }
      tokenLabel(labels[i]);
      if (stopFall) stopFall();
      const to = yOf(places[i]), from = how === 'step' ? lastY : to;
      stopFall = K.animate(how === 'step' ? 650 : 1, function (t) { ball.position.y = from + (to - from) * t; });
      lastY = to;
      return step;
    }
    return K.player(root, { count: spec.steps.length, show: show, speed: spec.speed });
  };
})();
