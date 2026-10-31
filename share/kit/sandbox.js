// LitmusKit.sandbox: the reader presses actions in any order and watches the state change.
// The model is plain JavaScript: a state, actions with a condition and an effect, and a
// view of the state as boxes. Items in boxes can be dragged to other boxes when the model
// says what a drop does. Every action is logged, and can be undone.
//
//   LitmusKit.sandbox('#reinstall', {
//     title: 'Upgrades and reinstalls',
//     state: { defaults: ['token'], keychain: [], signedIn: true },
//     boxes: [
//       { id: 'defaults', label: 'UserDefaults', items: s => s.defaults },
//       { id: 'keychain', label: 'Keychain', items: s => s.keychain },
//     ],
//     actions: [
//       { label: 'Launch the new version', run: s => { s.keychain = s.defaults.slice(); s.defaults = [];
//           return 'The token moves to the keychain.'; }, code: 'TokenService.migrate 1..12' },
//       { label: 'Delete the app', when: s => s.installed, run: s => { s.defaults = []; s.installed = false;
//           return 'UserDefaults goes with the app. The keychain stays.'; } },
//     ],
//     drop: (s, item, from, to) => { ... return 'what happened'; },   // optional: dragging items
//     switches: [{ key: 'markOnWrite', label: 'Mark the install on every write' }],
//     result: s => s.signedIn ? { text: 'Signed in', tone: 'good' } : { text: 'Signed out', tone: 'neutral' },
//     presets: [{ label: 'Reinstall', actions: ['Delete the app', 'Install again'] }],
//   });
//
// `run` changes the state it is given and returns a sentence for the log. An action whose
// `when` is false is disabled. A result's tone is 'good', 'bad' or 'neutral'.

(function () {
  'use strict';
  const K = window.LitmusKit;
  if (!K) throw new Error('sandbox.js needs kit.js first');

  K.addStyle('lmk-sandbox-style', `
.lmk-sandbox .lmk-world { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: .6em; margin: .6em 0; }
.lmk-sandbox .lmk-box { border: 2px solid #e2e8f0; border-radius: 9px; padding: .5em .65em; background: white; min-height: 4.2em;
  transition: border-color .3s, background .3s; }
.lmk-sandbox .lmk-box h4 { margin: 0 0 .35em; font-size: .78em; text-transform: uppercase; letter-spacing: .04em; color: #64748b; }
.lmk-sandbox .lmk-box.flash { border-color: #eab308; background: #fefce8; }
.lmk-sandbox .lmk-box.over { border-color: #2563eb; background: #eff6ff; }
.lmk-sandbox .lmk-item { display: inline-block; margin: .15em .25em .15em 0; padding: .1em .55em; border-radius: 999px; font-size: .85em;
  background: #fde68a; color: #713f12; }
.lmk-sandbox .lmk-item[draggable=true] { cursor: grab; }
.lmk-sandbox .lmk-none { color: #94a3b8; font-size: .85em; }
.lmk-sandbox .lmk-result { font-size: 1.15em; font-weight: 700; padding: .35em .7em; border-radius: 8px; text-align: center; }
.lmk-sandbox .lmk-good { background: #dcfce7; color: #166534; }
.lmk-sandbox .lmk-bad { background: #fee2e2; color: #991b1b; }
.lmk-sandbox .lmk-neutral { background: #f1f5f9; color: #475569; }
.lmk-sandbox .lmk-presets button { border-style: dashed; }
.lmk-sandbox .lmk-log { max-height: 10em; overflow-y: auto; border-top: 1px solid #e5e7eb; padding-top: .4em; font-size: .9em; line-height: 1.45; }
.lmk-sandbox .lmk-log div:first-child { font-weight: 600; }
.lmk-sandbox label { display: inline-flex; align-items: center; gap: .35em; cursor: pointer; }
`);

  const clone = function (x) { return JSON.parse(JSON.stringify(x)); };

  K.sandbox = function (target, spec) {
    const root = K.mountPoint(target, 'sandbox');
    if (spec.title) root.append(K.el('div', 'lmk-title', null, spec.title));
    let state = clone(spec.state || {}), history = [], log = [], flash = {};

    const actionsRow = K.el('div', 'lmk-row');
    const switchesRow = K.el('div', 'lmk-row');
    const presetsRow = K.el('div', 'lmk-row lmk-presets');
    const world = K.el('div', 'lmk-world');
    const result = K.el('div', 'lmk-result');
    const say = K.el('div', 'lmk-say', { 'aria-live': 'polite' });
    const logBox = K.el('div', 'lmk-log');
    root.append(actionsRow);
    if ((spec.switches || []).length) root.append(switchesRow);
    root.append(world);
    if (spec.result) root.append(result);
    root.append(say);
    if ((spec.presets || []).length) root.append(presetsRow);
    root.append(logBox);

    // Runs `apply`, which changes the state and returns a sentence, as one undoable action.
    function act(action, apply) {
      const before = clone(state);
      history.push({ state: before, log: log.slice() });
      const text = apply();
      flash = {};
      for (const b of spec.boxes || []) {
        if (JSON.stringify(b.items ? b.items(before) : before[b.id]) !== JSON.stringify(b.items ? b.items(state) : state[b.id])) flash[b.id] = true;
      }
      log.unshift(action.label + ': ' + (text || 'done.'));
      if (action && action.code) K.lightCode(action.code);
      render(text);
    }

    const buttons = (spec.actions || []).map(function (a) {
      const b = K.el('button', null, { type: 'button' }, a.label);
      b.onclick = function () { act(a, function () { return a.run(state); }); };
      actionsRow.append(b);
      return { action: a, button: b };
    });
    const undo = K.el('button', null, { type: 'button', title: 'Undo the last action' }, '↶ Undo');
    const reset = K.el('button', null, { type: 'button' }, 'Reset');
    actionsRow.append(undo, reset);
    undo.onclick = function () {
      const h = history.pop();
      if (!h) return;
      state = h.state; log = h.log; flash = {};
      render('Undone.');
    };
    reset.onclick = function () {
      state = clone(spec.state || {}); history = []; log = []; flash = {};
      render('Back to the start.');
    };

    for (const sw of spec.switches || []) {
      const box = K.el('input', null, { type: 'checkbox' });
      if (state[sw.key] === undefined) state[sw.key] = !!sw.value;
      box.checked = !!state[sw.key];
      box.onchange = function () {
        history.push({ state: clone(state), log: log.slice() });
        state[sw.key] = box.checked;
        log.unshift(sw.label + ': ' + (box.checked ? 'on' : 'off'));
        render(sw.say ? sw.say(state) : '');
      };
      sw.input = box;
      switchesRow.append(K.el('label', null, null, box, sw.label));
    }

    for (const preset of spec.presets || []) {
      const b = K.el('button', null, { type: 'button', title: preset.actions.join(' → ') }, '▶ ' + preset.label);
      b.onclick = function () {
        state = clone(spec.state || {}); history = []; log = [];
        for (const sw of spec.switches || []) state[sw.key] = sw.input.checked;
        let last = '';
        for (const label of preset.actions) {
          const a = (spec.actions || []).find(function (x) { return x.label === label; });
          if (a && (!a.when || a.when(state))) {
            last = a.run(state) || '';
            log.unshift(a.label + ': ' + (last || 'done.'));
          }
        }
        flash = {};
        render(last);
      };
      presetsRow.append(b);
    }

    // Dragging an item from one box to another, when the model says what a drop does.
    let dragged = null;
    function render(text) {
      for (const { action, button } of buttons) button.disabled = !!action.when && !action.when(state);
      undo.disabled = history.length === 0;
      world.innerHTML = '';
      for (const b of spec.boxes || []) {
        const box = K.el('div', 'lmk-box' + (flash[b.id] ? ' flash' : ''), null, K.el('h4', null, null, b.label));
        const items = b.items ? b.items(state) : state[b.id];
        const list = Array.isArray(items) ? items : (items == null || items === '' || items === false ? [] : [items]);
        if (!list.length) box.append(K.el('span', 'lmk-none', null, b.empty || 'nothing'));
        for (const item of list) {
          const chip = K.el('span', 'lmk-item', spec.drop ? { draggable: 'true' } : null, String(item));
          if (spec.drop) chip.addEventListener('dragstart', function (e) { dragged = { item: item, from: b.id }; e.dataTransfer.setData('text/plain', String(item)); });
          box.append(chip);
        }
        if (b.note) box.append(K.el('div', 'lmk-none', null, b.note(state)));
        if (spec.drop) {
          box.addEventListener('dragover', function (e) { e.preventDefault(); box.classList.add('over'); });
          box.addEventListener('dragleave', function () { box.classList.remove('over'); });
          box.addEventListener('drop', function (e) {
            e.preventDefault();
            box.classList.remove('over');
            if (!dragged || dragged.from === b.id) return;
            const d = dragged;
            dragged = null;
            act({ label: 'Drag ' + d.item + ' to ' + b.label }, function () { return spec.drop(state, d.item, d.from, b.id); });
          });
        }
        world.append(box);
      }
      if (spec.result) {
        const r = spec.result(state) || { text: '', tone: 'neutral' };
        result.className = 'lmk-result lmk-' + (r.tone || 'neutral');
        result.textContent = r.text;
      }
      say.innerHTML = text || spec.intro || 'Press an action.';
      logBox.innerHTML = '';
      for (const line of log) logBox.append(K.el('div', null, null, line));
    }
    render(spec.intro);
    return { get state() { return state; } };
  };
})();
