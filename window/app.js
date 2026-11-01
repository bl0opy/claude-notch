// The terminal window: every Claude Code session the agents daemon hosts, each
// drawn by xterm.js straight from its pty, plus the machine-wide roster.
//
// Two sockets: the roster (the same one the notch reads) for the lists, spend
// and session control, and one per open terminal for its bytes.

const $ = (id) => document.getElementById(id);

const state = {
  hosted: [], // [{id, cwd, running, exitCode, startedAt}]
  agents: [], // roster rows, every live session on the machine
  fleet: null,
  selected: null,
  roster: null,
};

const terms = new Map(); // id -> {term, fit, el, ws, closed}

// ---- formatting ----------------------------------------------------------

function money(n) {
  if (n == null) return '—';
  return n < 10 ? `$${n.toFixed(2)}` : `$${Math.round(n)}`;
}

function tokens(n) {
  if (!n) return '0';
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${Math.round(n / 1e3)}k`;
  return String(n);
}

function basename(path) {
  return path.replace(/\/+$/, '').split('/').pop() || path;
}

function heat(pct) {
  return pct >= 75 ? 'hot' : pct >= 50 ? 'warm' : '';
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'style') node.style.cssText = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const child of children) if (child != null) node.append(child);
  return node;
}

let toastTimer = null;
function toast(message) {
  const box = $('toast');
  box.textContent = message;
  box.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (box.hidden = true), 4000);
}

// ---- roster --------------------------------------------------------------

function send(msg) {
  if (state.roster?.readyState === WebSocket.OPEN) state.roster.send(JSON.stringify(msg));
  else toast('The agents daemon is not connected.');
}

// The notch's window sets this; the server won't hand it to just anyone.
const withToken = (url) => `${url}?token=${encodeURIComponent(window.notchToken || '')}`;

async function connectRoster() {
  let url = `ws://${location.hostname}:8767`;
  try {
    const config = await (await fetch('config.json')).json();
    url = config.roster || url;
    if (config.defaultPath) {
      const home = config.defaultPath.replace(/^\/Users\/[^/]+/, '~');
      $('spawn-path').placeholder = `a repo in ${home}, or a full path`;
      $('spawn-path').title = `Bare names are taken relative to ${home}`;
    }
  } catch {
    /* default port */
  }
  let delay = 500;
  const open = () => {
    const ws = new WebSocket(withToken(url));
    state.roster = ws;
    ws.onopen = () => {
      delay = 500;
      $('conn').classList.add('live');
      $('conn-text').textContent = 'agents daemon';
    };
    ws.onmessage = (e) => onRoster(JSON.parse(e.data));
    ws.onclose = () => {
      $('conn').classList.remove('live');
      $('conn-text').textContent = 'reconnecting';
      setTimeout(open, delay);
      delay = Math.min(delay * 2, 5000);
    };
  };
  open();
}

function onRoster(msg) {
  switch (msg.type) {
    case 'agents':
      state.agents = msg.list || [];
      state.fleet = msg.fleet || null;
      break;
    case 'hosted':
      state.hosted = msg.list || [];
      if (!state.selected && state.hosted.length && !location.hash) select(state.hosted[0].id);
      break;
    case 'spawned':
      // A resumed session starts a fresh screen in the same slot.
      terms.get(msg.id)?.term.reset();
      select(msg.id);
      break;
    case 'error':
      toast(msg.message || 'Something went wrong.');
      break;
    default:
      return;
  }
  render();
}

function row(id) {
  return state.agents.find((a) => a.id === id);
}

// ---- rendering -----------------------------------------------------------

function render() {
  const fleet = state.fleet;
  $('fleet-cost').textContent = fleet ? money(fleet.cost) : '—';
  $('fleet-tokens').textContent = fleet ? tokens(fleet.totalTokens) : '—';
  $('fleet-context').textContent = fleet?.context?.fullest
    ? `${Math.round(fleet.context.fullestPct)}% ${fleet.context.fullest}`
    : '—';

  const hostedIds = new Set(state.hosted.map((h) => h.id));
  $('hosted').replaceChildren(...state.hosted.map((h) => hostedRow(h, row(h.id))));
  $('elsewhere').replaceChildren(
    ...state.agents.filter((a) => !hostedIds.has(a.id)).map((a) => agentRow(a))
  );
  renderBar();
}

function stateOf(hosted, live) {
  if (hosted && !hosted.running) return 'stopped';
  return live?.state || 'idle';
}

function meter(pct) {
  const fill = el('div', { class: heat(pct), style: `width:${Math.min(100, pct || 0)}%` });
  return el('div', { class: 'meter' }, fill);
}

function rowBody(dotState, name, live, fallback) {
  const pct = live?.context?.pct || 0;
  const what = live?.activity
    ? `${live.activity}${live.activityDetail ? ` · ${live.activityDetail}` : ''}`
    : fallback;
  return [
    el('span', { class: `dot ${dotState}` }),
    el('span', { class: 'name', title: live?.cwd || '' }, name),
    el('span', { class: 'cost' }, live ? money(live.cost) : ''),
    el(
      'div',
      { class: 'sub' },
      el('span', { class: 'what' }, what),
      live ? meter(pct) : null
    ),
  ];
}

function hostedRow(hosted, live) {
  const dotState = stateOf(hosted, live);
  const name = live?.project || basename(hosted.cwd);
  const fallback = hosted.running ? live?.branch || 'starting' : 'stopped · resume to continue';
  const li = el(
    'li',
    { class: `row${hosted.id === state.selected ? ' selected' : ''}`, onclick: () => select(hosted.id) },
    ...rowBody(dotState, name, live, fallback)
  );
  return li;
}

function agentRow(agent) {
  const where = agent.host ? `in ${agent.host}` : 'headless';
  return el('li', { class: 'row', title: agent.cwd }, ...rowBody(agent.state, agent.project, agent, where));
}

function renderBar() {
  const hosted = state.hosted.find((h) => h.id === state.selected);
  $('bar').hidden = !hosted;
  $('empty').hidden = Boolean(hosted);
  if (!hosted) return;
  const live = row(hosted.id);
  const dotState = stateOf(hosted, live);
  $('bar-dot').className = `dot ${dotState}`;
  $('bar-project').textContent = live?.project || basename(hosted.cwd);
  $('bar-branch').textContent = live?.branch || '';
  $('bar-model').textContent = live?.model || '';
  const ctx = live?.context;
  $('bar-fill').className = heat(ctx?.pct || 0);
  $('bar-fill').style.width = `${Math.min(100, ctx?.pct || 0)}%`;
  $('bar-context').textContent = ctx ? `${tokens(ctx.used)} / ${tokens(ctx.window)}` : '';
  $('bar-cost').textContent = live ? money(live.cost) : '';
  $('act-esc').hidden = !hosted.running;
  $('act-stop').hidden = !hosted.running;
  $('act-resume').hidden = hosted.running;
  $('act-forget').hidden = hosted.running;
  document.title = `${$('bar-project').textContent} — Notch Agents`;
}

// ---- terminals -----------------------------------------------------------

function themeFromCss() {
  const css = getComputedStyle(document.documentElement);
  const v = (name) => css.getPropertyValue(name).trim();
  return {
    background: v('--term-bg'),
    foreground: v('--term-fg'),
    cursor: v('--term-fg'),
    cursorAccent: v('--term-bg'),
    selectionBackground: 'rgba(255, 255, 255, 0.18)',
  };
}

function select(id) {
  state.selected = id;
  if (location.hash.slice(1) !== id) history.replaceState(null, '', `#${id}`);
  for (const [tid, t] of terms) t.el.hidden = tid !== id;
  if (id && !terms.has(id)) openTerm(id);
  const t = terms.get(id);
  if (t) {
    fit(t);
    t.term.focus();
  }
  render();
}

function openTerm(id) {
  const box = el('div', { class: 'term' });
  $('terms').append(box);
  const term = new Terminal({
    fontFamily: getComputedStyle(document.documentElement).getPropertyValue('--font-mono').trim(),
    fontSize: 12.5,
    lineHeight: 1.15,
    cursorBlink: true,
    allowProposedApi: true,
    macOptionIsMeta: true,
    scrollback: 5000,
    theme: themeFromCss(),
  });
  const fitter = new FitAddon.FitAddon();
  term.loadAddon(fitter);
  term.open(box);
  const entry = { term, fit: fitter, el: box, ws: null, closed: false };
  terms.set(id, entry);

  term.onData((data) => sendPty(entry, { type: 'in', data }));
  term.onResize(({ cols, rows }) => sendPty(entry, { type: 'resize', cols, rows }));
  connectPty(id, entry);
}

function sendPty(entry, msg) {
  if (entry.ws?.readyState === WebSocket.OPEN) entry.ws.send(JSON.stringify(msg));
}

function connectPty(id, entry) {
  const ws = new WebSocket(withToken(`ws://${location.host}/pty/${id}`));
  entry.ws = ws;
  ws.onopen = () => {
    fit(entry);
    sendPty(entry, { type: 'resize', cols: entry.term.cols, rows: entry.term.rows });
  };
  ws.onmessage = (e) => {
    const frame = JSON.parse(e.data);
    if (frame.type === 'replay') {
      entry.term.reset();
      entry.term.write(frame.data);
    } else if (frame.type === 'out') {
      entry.term.write(frame.data);
    } else if (frame.type === 'exit') {
      entry.term.write(`\r\n\x1b[2m[session ended${frame.code ? ` · ${frame.code}` : ''}]\x1b[0m\r\n`);
    }
  };
  ws.onclose = (e) => {
    if (entry.closed || e.code === 4404) return;
    // The daemon restarted; the session may be back once it has.
    setTimeout(() => terms.get(id) === entry && connectPty(id, entry), 1500);
  };
}

function fit(entry) {
  if (entry.el.hidden) return;
  try {
    entry.fit.fit();
  } catch {
    /* not laid out yet */
  }
}

function dropTerm(id) {
  const entry = terms.get(id);
  if (!entry) return;
  entry.closed = true;
  entry.ws?.close();
  entry.term.dispose();
  entry.el.remove();
  terms.delete(id);
}

new ResizeObserver(() => {
  const entry = terms.get(state.selected);
  if (entry) fit(entry);
}).observe($('terms'));

// ---- controls ------------------------------------------------------------

$('spawn').addEventListener('submit', (e) => {
  e.preventDefault();
  const path = $('spawn-path').value.trim();
  if (!path) return;
  // The daemon expands ~ itself.
  send({ type: 'spawn', cwd: path });
  $('spawn-path').value = '';
});

$('act-esc').onclick = () => {
  send({ type: 'interrupt', id: state.selected });
  terms.get(state.selected)?.term.focus();
};
$('act-stop').onclick = () => send({ type: 'stop', id: state.selected });
$('act-resume').onclick = () => send({ type: 'resume', id: state.selected });
$('act-forget').onclick = () => {
  const id = state.selected;
  send({ type: 'forget', id });
  dropTerm(id);
  state.selected = null;
  history.replaceState(null, '', location.pathname);
  render();
};

window.addEventListener('hashchange', () => {
  const id = location.hash.slice(1);
  if (id && id !== state.selected) select(id);
});

// The notch opens this window on a session by setting the hash.
window.focusSession = (id) => select(id);

if (location.hash.length > 1) select(location.hash.slice(1));
render();
connectRoster();
