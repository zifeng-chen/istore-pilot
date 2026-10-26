'use strict';

const $ = (s) => document.querySelector(s);
const $$ = (s) => Array.from(document.querySelectorAll(s));

const store = {
  get(k, d) { try { const v = localStorage.getItem('istore.' + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('istore.' + k, JSON.stringify(v)); } catch {} },
  del(k) { try { localStorage.removeItem('istore.' + k); } catch {} },
};

// 在 App 壳里（WebView 加载本地页或 file://）location.origin 不是路由地址，
// 直接拿来当 API 基址会全盘失败，所以只在 http(s) 下采用，否则退回已存/默认地址。
const DEFAULT_LAN = 'http://192.168.100.1:8443';

function saneOrigin() {
  const o = location.origin;
  return /^https?:\/\/[^/]+/.test(o) && o !== 'null' ? o : '';
}

const state = {
  base: saneOrigin() || store.get('lanAddr', '') || DEFAULT_LAN,
  token: store.get('token', ''),
  env: 'unknown',
  timer: null,
  clashTimer: null,
  spark: { rx: [], tx: [] },
  groups: [],
  backend: '',
  busy: false,
};

/* ---------------------------------------------------------------- 格式化 */

const fmtRate = (bytesPerSec) => {
  const v = (bytesPerSec || 0) * 8;
  if (v >= 1e9) return [(v / 1e9).toFixed(2), 'Gbps'];
  if (v >= 1e6) return [(v / 1e6).toFixed(1), 'Mbps'];
  if (v >= 1e3) return [(v / 1e3).toFixed(0), 'Kbps'];
  return [String(Math.round(v)), 'bps'];
};
const fmtBytes = (n) => {
  if (!n) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n < 10 ? n.toFixed(1) : Math.round(n)} ${u[i]}`;
};
const fmtDuration = (sec) => {
  sec = Math.max(0, Math.floor(sec || 0));
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  if (d > 0) return `${d} 天 ${h} 小时`;
  if (h > 0) return `${h} 小时 ${m} 分`;
  return `${m} 分钟`;
};
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function toast(msg) {
  const el = $('#toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => el.classList.remove('show'), 1800);
}

/* ---------------------------------------------------------------- 地址探测 */

function candidates() {
  const list = [];
  const lan = store.get('lanAddr', '');
  const wan = store.get('wanAddr', '');
  if (lan) list.push({ url: lan.replace(/\/+$/, ''), kind: 'lan' });
  if (wan) list.push({ url: wan.replace(/\/+$/, ''), kind: 'wan' });
  if (!list.length) list.push({ url: saneOrigin() || DEFAULT_LAN, kind: 'local' });
  return list;
}

async function probe(url, timeout = 1500) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeout);
  const started = performance.now();
  try {
    const res = await fetch(url + '/api/v1/ping', { signal: ctrl.signal, cache: 'no-store' });
    if (!res.ok) return null;
    const data = await res.json();
    return data && data.ok ? { url, ms: Math.round(performance.now() - started) } : null;
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

let switching = null;
async function resolveBase(force = false) {
  if (switching) return switching;
  switching = (async () => {
    const list = candidates();
    const current = list.find((c) => c.url === state.base);
    if (current && !force) {
      const ok = await probe(current.url, 1200);
      if (ok) { state.env = current.kind === 'local' ? 'lan' : current.kind; return state.base; }
    }
    const results = await Promise.all(list.map(async (c) => {
      const r = await probe(c.url);
      return r ? { ...c, ...r } : null;
    }));
    const winner = results.filter(Boolean).sort((a, b) => a.ms - b.ms)[0];
    if (winner) {
      state.base = winner.url;
      state.env = winner.kind === 'local' ? 'lan' : winner.kind;
      return state.base;
    }
    return null;
  })();
  try { return await switching; } finally { switching = null; }
}

/* ---------------------------------------------------------------- 请求 */

async function api(path, opts = {}) {
  const headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers || {});
  if (state.token) headers.Authorization = 'Bearer ' + state.token;
  const res = await fetch(state.base + '/api/v1' + path, { ...opts, headers, cache: 'no-store' });
  if (res.status === 401) {
    state.token = '';
    store.del('token');
    showLogin('登录已过期，请重新输入密码');
    throw new Error('unauthorized');
  }
  if (!res.ok) throw new Error('HTTP ' + res.status);
  return res.json();
}

/* ---------------------------------------------------------------- 登录 */

function showLogin(msg = '') {
  $('#login').style.display = 'flex';
  $('#login-err').textContent = msg;
  $('#login-btn').disabled = false;
  setTimeout(() => $('#pwd').focus(), 100);
}

async function doLogin() {
  const btn = $('#login-btn');
  btn.disabled = true;
  $('#login-err').textContent = '';
  try {
    const base = await resolveBase(true);
    if (!base) throw new Error('unreachable');
    const res = await fetch(base + '/api/v1/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: $('#pwd').value }),
    });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || '密码错误');
    state.token = data.token;
    store.set('token', data.token);
    $('#login').style.display = 'none';
    $('#pwd').value = '';
    boot();
  } catch (e) {
    $('#login-err').textContent = e.message === 'unreachable' ? '连不上路由器，请检查网络或设置里的地址' : e.message;
    btn.disabled = false;
  }
}

/* ---------------------------------------------------------------- 概览渲染 */

function setNum(id, value, unit) {
  const el = $(id);
  if (!el) return;
  el.innerHTML = `${value}${unit ? `<small>${unit}</small>` : ''}`;
}

function renderOverview(d) {
  const b = d.board || {};
  $('#hostname').textContent = b.hostname || 'iStoreOS';
  $('#hostsub').textContent = state.base.replace(/^https?:\/\//, '');

  const up = d.network?.wan?.up;
  const badge = $('#online-badge');
  badge.classList.toggle('down', !up);
  $('#online-text').textContent = up ? '在线' : '离线';

  setNum('#m-cpu', Math.round(d.cpu.percent), '%');
  setNum('#m-mem', Math.round(d.memory.percent), '%');
  const temps = (d.temperature || []).filter((t) => t.label !== 'acpitz');
  const tmax = temps.length ? Math.max(...temps.map((t) => t.celsius)) : (d.temperature?.[0]?.celsius ?? null);
  setNum('#m-temp', tmax == null ? '–' : `${Math.round(tmax)}°`);
  setNum('#m-load', (d.load.load1 || 0).toFixed(2));

  const wan = d.network?.wan || {};
  $('#wan-proto').textContent = (wan.proto || '').toUpperCase();
  $('#wan-v4').textContent = wan.ipv4?.[0]?.address || '—';
  const v6 = (wan.ipv6 || []).map((a) => a.address).filter((a) => a && !a.startsWith('fe80'))[0];
  $('#wan-v6').textContent = v6 || '—';
  $('#wan-gw').textContent = wan.gateway || '—';
  $('#wan-dns').textContent = (wan.dns || []).join(' / ') || '—';
  $('#wan-up').textContent = wan.uptime ? fmtDuration(wan.uptime) : '—';

  const ports = d.network?.ports || [];
  const active = ports.filter((p) => p.up).length;
  $('#port-count').textContent = `${active}/${ports.length} 已连接`;
  $('#ports').innerHTML = ports.map((p) => `
    <div class="port">
      <span class="led ${p.up ? 'on' : ''}"></span>
      <span class="name">${esc(p.name)}</span>
      <span class="meta">${p.up
        ? `${p.speed_mbps ? p.speed_mbps + ' Mbps' : '已连接'}${p.rx_bps > 1024 ? ' · ' + fmtRate(p.rx_bps).join(' ') : ''}`
        : '未连接'}</span>
    </div>`).join('') || '<div class="empty">无网口</div>';

  $('#storage').innerHTML = (d.storage || []).map((s) => {
    const cls = s.percent > 90 ? 'danger' : s.percent > 75 ? 'warn' : '';
    return `<div style="padding:6px 0">
      <div class="row" style="border:none;padding:0">
        <span class="k">${esc(s.mount)}</span>
        <span class="v small">${fmtBytes(s.used)} / ${fmtBytes(s.total)}</span>
      </div>
      <div class="bar ${cls}"><i style="width:${Math.min(100, s.percent)}%"></i></div>
    </div>`;
  }).join('') || '<div class="empty">无挂载磁盘</div>';

  $('#sys-fw').textContent = b.version ? `iStoreOS ${b.version}` : '—';
  $('#sys-kernel').textContent = b.kernel || '—';
  $('#sys-cpu').textContent = `${d.cpu.model} · ${d.cpu.cores} 核`;
  $('#sys-uptime').textContent = fmtDuration(d.uptime);
}

/* ---------------------------------------------------------------- 流量图 */

function pushSpark(rx, tx) {
  state.spark.rx.push(rx || 0);
  state.spark.tx.push(tx || 0);
  if (state.spark.rx.length > 60) { state.spark.rx.shift(); state.spark.tx.shift(); }
  drawSpark();
}

function drawSpark() {
  const cv = $('#spark');
  if (!cv) return;
  const dpr = window.devicePixelRatio || 1;
  const w = cv.clientWidth, h = cv.clientHeight;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
    cv.width = Math.round(w * dpr);
    cv.height = Math.round(h * dpr);
  }
  const ctx = cv.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);

  const all = state.spark.rx.concat(state.spark.tx);
  const max = Math.max(1024, ...all);
  const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#0a84ff';
  const muted = getComputedStyle(document.documentElement).getPropertyValue('--faint').trim() || '#9aa0a6';

  const plot = (arr, color, fill) => {
    if (arr.length < 2) return;
    const step = w / 59;
    ctx.beginPath();
    arr.forEach((v, i) => {
      const x = i * step;
      const y = h - 3 - (v / max) * (h - 8);
      i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
    });
    if (fill) {
      ctx.lineTo((arr.length - 1) * step, h);
      ctx.lineTo(0, h);
      ctx.closePath();
      ctx.fillStyle = fill;
      ctx.fill();
      ctx.beginPath();
      arr.forEach((v, i) => {
        const x = i * step;
        const y = h - 3 - (v / max) * (h - 8);
        i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      });
    }
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.6;
    ctx.lineJoin = 'round';
    ctx.stroke();
  };

  plot(state.spark.tx, muted, null);
  plot(state.spark.rx, accent, 'rgba(10,132,255,.10)');
}

/* ---------------------------------------------------------------- 网络页 */

async function loadNet() {
  const [clients, net] = await Promise.all([
    api('/clients').catch(() => ({ clients: [] })),
    api('/network').catch(() => null),
  ]);

  const list = clients.clients || [];
  $('#client-count').textContent = `${list.length} 台`;
  $('#clients').innerHTML = list.length ? list.map((c) => `
    <div class="row">
      <span class="k" style="color:var(--text);font-weight:500">${esc(c.hostname || c.mac)}</span>
      <span class="v mono">${esc(c.ip)}</span>
    </div>`).join('') : '<div class="empty">暂无租约记录</div>';

  if (!net) return;
  const rows = [];
  for (const iface of [net.wan, net.lan]) {
    for (const a of iface.ipv4 || []) rows.push([`${iface.label} IPv4`, a.address]);
    for (const a of iface.ipv6 || []) {
      if (a.address && !a.address.startsWith('fe80')) rows.push([`${iface.label} IPv6`, a.address]);
    }
  }
  for (const p of net.ports || []) {
    if (p.up && p.mac) rows.push([`${p.name} MAC`, p.mac]);
  }
  $('#ifaddrs').innerHTML = rows.map(([k, v]) =>
    `<div class="row"><span class="k">${esc(k)}</span><span class="v mono">${esc(v)}</span></div>`).join('');
}

/* ---------------------------------------------------------------- 代理页 */

const DELAY_CLS = (d) => (d == null ? '' : d < 250 ? 'good' : d < 700 ? 'mid' : 'bad');

const MODES = {
  openclash: [['rule', '规则'], ['global', '全局'], ['direct', '直连']],
  passwall: [['proxy', '代理'], ['disable', '直连']],
};

function renderGroups() {
  const box = $('#groups');
  if (!state.groups.length) { box.innerHTML = '<div class="empty">没有可用的策略组</div>'; return; }
  const ordered = state.groups.filter((g) => g.name !== 'GLOBAL')
    .concat(state.groups.filter((g) => g.name === 'GLOBAL'));
  box.innerHTML = ordered.map((g, gi) => `
    <div class="group" data-gi="${gi}">
      <div class="gh">
        <div style="min-width:0">
          <div class="gname">${esc(g.name)}</div>
          <div class="gnow">${esc(g.now || '—')}${g.now_delay ? ' · ' + g.now_delay + 'ms' : ''}</div>
        </div>
        <span class="chev">›</span>
      </div>
      <div class="nodes">
        ${g.members.map((m) => `
          <div class="node ${m.name === g.now ? 'on' : ''}" data-group="${esc(g.name)}" data-name="${esc(m.name)}">
            <span class="nm">${esc(m.name)}</span>
            ${m.is_group ? '<span class="dl">组</span>' : ''}
            <span class="dl ${DELAY_CLS(m.delay)}">${m.delay ? m.delay + 'ms' : '—'}</span>
          </div>`).join('')}
      </div>
    </div>`).join('');

  box.querySelectorAll('.gh').forEach((h) => {
    h.addEventListener('click', () => h.parentElement.classList.toggle('open'));
  });
  box.querySelectorAll('.node').forEach((n) => {
    n.addEventListener('click', () => selectNode(n.dataset.group, n.dataset.name));
  });
}

function renderBackends(d) {
  const seg = $('#backend-seg');
  seg.querySelectorAll('button').forEach((b) => {
    const item = (d.backends || []).find((x) => x.id === b.dataset.backend);
    b.classList.toggle('on', b.dataset.backend === state.backend);
    b.classList.toggle('muted-btn', !item || !item.installed);
    b.disabled = !item || !item.installed;
  });

  $('#proxy-active').textContent = d.active === 'none' ? '未运行' : `当前生效：${d.active === 'openclash' ? 'OpenClash' : 'Passwall'}`;

  $('#backend-info').innerHTML = (d.backends || []).map((b) => `
    <div class="row">
      <span class="k">${esc(b.label)}</span>
      <span class="v small">
        ${b.installed ? (b.running ? '运行中' : b.enabled ? '已启用未运行' : '未启用') : '未安装'}
        · ${b.node_count || 0} 节点
        ${b.engine ? ' · ' + esc(b.engine) : ''}
      </span>
    </div>`).join('');
}

async function loadProxy() {
  const [ov, groups, conns, md] = await Promise.all([
    api('/proxy').catch(() => null),
    api('/proxy/groups' + (state.backend ? '?backend=' + encodeURIComponent(state.backend) : '')).catch(() => null),
    api('/proxy/connections' + (state.backend ? '?backend=' + encodeURIComponent(state.backend) : '')).catch(() => null),
    api('/proxy/mode').catch(() => null),
  ]);

  if (ov) {
    if (!state.backend) {
      state.backend = ov.active === 'passwall' ? 'passwall' : 'openclash';
    }
    renderBackends(ov);
    const cur = (ov.backends || []).find((b) => b.id === state.backend) || {};
    const badge = $('#clash-badge');
    badge.classList.toggle('down', !cur.running);
    $('#clash-state').textContent = cur.running ? '运行中' : cur.enabled ? '已启用未运行' : '已停止';
    $('#proxy-title').textContent = cur.label || '代理';
    $('#clash-core').textContent = [cur.engine, cur.mode].filter(Boolean).join(' · ') || '—';
    $('#clash-nodes').textContent = cur.node_count ? `${cur.node_count} 个` : '—';

    const seg = $('#mode-seg');
    const modes = MODES[state.backend] || MODES.openclash;
    if (seg.dataset.backend !== state.backend) {
      seg.dataset.backend = state.backend;
      seg.innerHTML = modes.map(([v, t]) => `<button data-mode="${v}">${t}</button>`).join('');
      seg.querySelectorAll('button').forEach((b) => b.addEventListener('click', () => setMode(b.dataset.mode)));
    }
    if (md && md.mode) {
      seg.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.mode === md.mode));
    }
  }

  if (conns) {
    $('#clash-conns').textContent = conns.error ? '—' : (conns.connections?.length || 0) + ' 条';
  }

  if (groups && !groups.error) {
    state.groups = groups.groups || [];
    renderGroups();
  } else if (groups?.error) {
    $('#groups').innerHTML = `<div class="empty">${esc(groups.error)}</div>`;
    state.groups = [];
  }
}

async function switchBackend(backend) {
  if (state.busy || backend === state.backend) return;
  state.busy = true;
  state.backend = backend;
  state.groups = [];
  $('#groups').innerHTML = '<div class="empty">读取中…</div>';
  try {
    await loadProxy();
  } finally {
    state.busy = false;
  }
}

async function selectNode(group, name) {
  if (state.busy) return;
  state.busy = true;
  toast('切换中…');
  try {
    const r = await api('/proxy/select', {
      method: 'POST',
      body: JSON.stringify({ group, name, backend: state.backend }),
    });
    if (!r.ok) throw new Error(r.error || '切换失败');
    toast(r.restarted ? `已切换到 ${name}，内核重启中` : `已切换到 ${name}`);
    if (r.restarted) setTimeout(loadProxy, 2500);
    else await loadProxy();
  } catch (e) {
    toast(e.message);
  } finally {
    state.busy = false;
  }
}

async function setMode(mode) {
  try {
    const r = await api('/proxy/mode', {
      method: 'POST',
      body: JSON.stringify({ mode, backend: state.backend }),
    });
    if (!r.ok) throw new Error(r.error);
    toast('模式已切换');
    loadProxy();
  } catch (e) { toast(e.message); }
}

async function serviceAction(action) {
  const label = state.backend === 'passwall' ? 'Passwall' : 'OpenClash';
  const verb = action === 'stop' ? '停止' : action === 'start' ? '启动' : '重启';
  const other = state.backend === 'passwall' ? 'OpenClash' : 'Passwall';
  const warn = action === 'start' || action === 'restart'
    ? `\n\n如果 ${other} 正在运行，会先被停掉。` : '';
  if (!confirm(`确定要${verb} ${label} 吗？${warn}`)) return;
  toast('执行中…');
  try {
    const r = await api('/proxy/service', {
      method: 'POST',
      body: JSON.stringify({ action, backend: state.backend }),
    });
    toast(r.ok ? `${verb}完成${r.stopped_other ? '（已停 ' + r.stopped_other + '）' : ''}` : '失败：' + (r.error || r.code));
    setTimeout(loadProxy, 1500);
  } catch (e) { toast(e.message); }
}

async function testAll() {
  toast('测速中…');
  const groups = state.groups.filter((g) => g.name !== 'GLOBAL');
  const targets = groups.slice(0, 2).flatMap((g) => g.members.filter((m) => !m.is_group)).slice(0, 12);
  await Promise.all(targets.map((m) =>
    api('/proxy/delay', {
      method: 'POST',
      body: JSON.stringify({ name: m.name, backend: state.backend }),
    }).catch(() => null)));
  toast('测试完成');
  loadProxy();
}

/* ---------------------------------------------------------------- 设置页 */

function renderSettings() {
  $('#set-addr').textContent = state.base.replace(/^https?:\/\//, '');
  const lan = store.get('lanAddr', ''), wan = store.get('wanAddr', '');
  $('#set-alt').textContent = (state.env === 'wan' ? lan : wan).replace(/^https?:\/\//, '') || '未设置';
  const envText = state.env === 'wan' ? '外网' : state.env === 'unknown' ? '未知' : '内网直连';
  $('#set-env').textContent = envText;
  $('#in-lan').value = lan || defaultLan();
  $('#in-wan').value = wan || '';
  loadPower();
  loadAdblock();
}

function defaultLan() {
  return /^https?:\/\/(\d{1,3}\.){3}\d{1,3}(:\d+)?$/.test(location.origin)
    ? location.origin
    : 'http://192.168.100.1:8443';
}

/* ---------------------------------------------------------------- 电源控制 */

const DANGER_ACTIONS = { reboot: '重启路由器', poweroff: '关闭路由器' };

async function loadPower() {
  let d;
  try { d = await api('/power'); } catch { return; }
  const box = $('#power-actions');
  box.innerHTML = (d.actions || []).map((a) => `
    <div class="row">
      <span class="k">${esc(a.label)}</span>
      <button class="btn ${a.danger ? 'danger' : 'ghost'} small" data-action="${esc(a.id)}"
        style="padding:6px 12px">${a.danger ? '执行' : '执行'}</button>
    </div>`).join('');

  box.querySelectorAll('button[data-action]').forEach((b) => {
    b.addEventListener('click', () => runPower(b.dataset.action));
  });

  $('#power-warn').textContent = d.warning || '';
}

async function runPower(action) {
  const label = DANGER_ACTIONS[action];
  if (label) {
    if (!confirm(`${label}？\n\n执行后连接会中断，需要等待设备重新上线。`)) return;
    // 危险操作要求输入一次动作名，避免手滑
    const typed = prompt(`这是不可撤销的操作。请再次输入「${action}」确认：`);
    if (typed !== action) { toast('已取消'); return; }
  } else if (!confirm('确定要执行吗？短暂断网后自动恢复。')) {
    return;
  }

  toast('执行中…');
  try {
    const r = await api('/power', {
      method: 'POST',
      body: JSON.stringify({ action, confirm: label ? action : '' }),
    });
    if (!r.ok) throw new Error(r.error || '执行失败');
    toast(r.message || `${r.label || ''}已下发`);
    if (label) {
      $('#online-text').textContent = '重启中';
      $('#online-badge').classList.add('down');
    }
  } catch (e) { toast(e.message); }
}

/* ---------------------------------------------------------------- 广告拦截 */

async function loadAdblock() {
  const box = $('#ad-checks');
  let st, pf;
  try {
    [st, pf] = await Promise.all([
      api('/adblock').catch(() => null),
      api('/adblock/preflight').catch(() => null),
    ]);
  } catch {
    box.innerHTML = '<div class="empty">读取失败</div>';
    return;
  }
  if (!st) { box.innerHTML = '<div class="empty">读取失败</div>'; return; }

  const badge = $('#ad-badge');
  const on = st.mode === 'takeover';
  badge.classList.toggle('down', !st.running);
  $('#ad-state').textContent = st.mode_label || '未知';

  $('#ad-rules').textContent = st.filters?.rules
    ? `${st.filters.rules.toLocaleString()} 条 · ${st.filters.enabled} 个列表`
    : '未加载';
  $('#ad-stats').textContent = st.stats?.queries
    ? `${st.stats.queries.toLocaleString()} / ${st.stats.blocked.toLocaleString()}（${st.stats.percent}%）`
    : '暂无数据';
  $('#ad-owner').textContent = on ? 'AdGuard Home（已接管）' : `dnsmasq（AGH 只在 5353）`;

  const btn = $('#ad-toggle');
  btn.textContent = on ? '退出接管' : '接管全网';
  btn.classList.toggle('danger', on);

  if (pf) {
    box.innerHTML = (pf.checks || []).map((c) => `
      <div class="check ${c.ok ? 'ok' : 'bad'}">
        <span class="mark">${c.ok ? '✓' : '!'}</span>
        <div style="min-width:0">
          <div class="ck-label">${esc(c.label)}</div>
          <div class="ck-detail">${esc(c.detail)}</div>
        </div>
      </div>`).join('');
    $('#ad-notes').innerHTML = (pf.notes || []).map((n) => `<div>· ${esc(n)}</div>`).join('');
  }
}

async function adblockAction(path, confirmText, okText, btn) {
  if (confirmText && !confirm(confirmText)) return;
  btn = btn || $('#ad-toggle');
  btn.disabled = true;
  toast('执行中…');
  try {
    const r = await api(path, { method: 'POST', body: JSON.stringify({}) });
    if (!r.ok) throw new Error(r.error || r.message || '执行失败');
    toast(r.message || okText);
    // 切换 DNS 后需要几秒让服务起停完成
    setTimeout(loadAdblock, 2500);
  } catch (e) {
    toast(e.message);
  } finally {
    btn.disabled = false;
  }
}


/* ---------------------------------------------------------------- 轮询 */

async function pollTraffic() {
  try {
    const t = await api('/traffic');
    const [rv, ru] = fmtRate(t.wan.rx_bps);
    const [tv, tu] = fmtRate(t.wan.tx_bps);
    $('#rx').innerHTML = `${rv} <small>${ru}</small>`;
    $('#tx').innerHTML = `${tv} <small>${tu}</small>`;
    pushSpark(t.wan.rx_bps, t.wan.tx_bps);
  } catch {}
}

async function refreshOverview() {
  try {
    const d = await api('/overview');
    renderOverview(d);
    document.body.dataset.ok = '1';
  } catch (e) {
    if (String(e.message) === 'unauthorized') return;
    $('#online-text').textContent = '断线';
    $('#online-badge').classList.add('down');
  }
}

function startPolling() {
  clearInterval(state.timer);
  clearInterval(state.clashTimer);
  state.timer = setInterval(() => {
    if (document.hidden) return;
    refreshOverview();
    if ($('#page-home').classList.contains('active')) pollTraffic();
  }, 3000);
  state.clashTimer = setInterval(() => {
    if (!document.hidden && $('#page-clash').classList.contains('active')) loadProxy();
  }, 6000);
}

/* ---------------------------------------------------------------- 导航 */

function switchPage(name) {
  $$('.page').forEach((p) => p.classList.toggle('active', p.id === 'page-' + name));
  $$('.nav a').forEach((a) => a.classList.toggle('on', a.dataset.page === name));
  if (name === 'net') loadNet();
  if (name === 'clash') loadProxy();
  if (name === 'settings') renderSettings();
  if (name === 'home') { refreshOverview(); pollTraffic(); }
}

/* ---------------------------------------------------------------- 启动 */

async function boot() {
  const base = await resolveBase();
  if (!base) {
    showLogin('找不到路由器，请确认已连接到它的网络');
    return;
  }
  if (!state.token) { showLogin(); return; }
  $('#login').style.display = 'none';
  try {
    const h = await api('/health');
    // 这里原来显示「Agent 12345s」，秒数没人看得懂，改成版本 + 人类可读的运行时长
    $('#set-agent').textContent = `v${h.version || '?'} · 已运行 ${fmtDuration(h.uptime)}`;
  } catch {}
  await refreshOverview();
  await pollTraffic();
  startPolling();
}

function seedLanAddr() {
  if (store.get('lanAddr')) return;
  if (/^https?:\/\/(\d{1,3}\.){3}\d{1,3}(:\d+)?$/.test(location.origin)) {
    store.set('lanAddr', location.origin);
  }
}

function init() {
  seedLanAddr();
  $('#login-btn').addEventListener('click', doLogin);
  $('#pwd').addEventListener('keydown', (e) => { if (e.key === 'Enter') doLogin(); });

  $$('.nav a').forEach((a) => a.addEventListener('click', (e) => {
    e.preventDefault();
    switchPage(a.dataset.page);
  }));

  $$('#mode-seg button').forEach((b) => b.addEventListener('click', () => setMode(b.dataset.mode)));
  $$('#backend-seg button').forEach((b) => b.addEventListener('click', () => switchBackend(b.dataset.backend)));
  $('#clash-restart').addEventListener('click', () => serviceAction('restart'));
  $('#clash-stop').addEventListener('click', () => serviceAction('stop'));
  $('#clash-start').addEventListener('click', () => serviceAction('start'));
  $('#test-all').addEventListener('click', testAll);

  $('#ad-toggle').addEventListener('click', () => {
    const btn = $('#ad-toggle');
    if ($('#ad-state').textContent === '已接管全网') {
      adblockAction('/adblock/release',
        '退出接管？\n\nDNS 会回到 dnsmasq，广告拦截立即失效，网络恢复原状。', '已退出接管', btn);
    } else {
      adblockAction('/adblock/takeover',
        '接管全网 DNS？\n\n所有设备的上网请求会先经 AdGuard Home 过滤，再交给 OpenClash 分流。\n\n出问题可随时一键退出，不需要重启路由器。', '已接管', btn);
    }
  });
  $('#ad-refresh').addEventListener('click', () =>
    adblockAction('/adblock/refresh', '', '规则已更新', $('#ad-refresh')));

  $('#save-addr').addEventListener('click', async () => {    store.set('lanAddr', $('#in-lan').value.trim());
    store.set('wanAddr', $('#in-wan').value.trim());
    const base = await resolveBase(true);
    toast(base ? '已切换到 ' + base.replace(/^https?:\/\//, '') : '两个地址都连不上');
    renderSettings();
    refreshOverview();
  });

  $('#logout').addEventListener('click', () => {
    state.token = '';
    store.del('token');
    location.reload();
  });

  $('#pw-save').addEventListener('click', async () => {
    const cur = $('#pw-cur').value, next = $('#pw-new').value;
    if (next.length < 8) { toast('新密码至少 8 位'); return; }
    try {
      const r = await api('/password', { method: 'POST', body: JSON.stringify({ current: cur, new: next }) });
      if (!r.ok) throw new Error(r.error || '修改失败');
      toast('密码已更新');
      $('#pw-cur').value = '';
      $('#pw-new').value = '';
    } catch (e) { toast(e.message); }
  });

  window.addEventListener('online', () => resolveBase(true).then(() => refreshOverview()));
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) { resolveBase().then(() => refreshOverview()); }
  });

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  }

  boot();
}

document.addEventListener('DOMContentLoaded', init);
