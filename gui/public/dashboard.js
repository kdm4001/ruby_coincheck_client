const $ = id => document.getElementById(id);
const pairs = ['btc_jpy', 'eth_jpy', 'xrp_jpy', 'sol_jpy'];
const yen = value => Number(value).toLocaleString('ja-JP', { maximumFractionDigits: 2 });
const preference = 'coincheck-local-view';

export function setupDashboard({ api, selectPair }) {
  let loading = false, enabled = true, wakeLock, keepAwake = false, acquiring = false;
  const quotes = new Map();
  const cards = new Map();
  for (const pair of pairs) {
    const card = document.createElement('button');
    card.type = 'button'; card.className = 'watch-card';
    const name = document.createElement('span'); name.className = 'watch-name';
    name.textContent = pair.toUpperCase().replace('_', ' / ');
    const price = document.createElement('strong'); price.textContent = '—';
    const range = document.createElement('span'); range.className = 'watch-range'; range.textContent = '24h 安値 — / 高値 —';
    const status = document.createElement('small'); status.textContent = '取得待ち';
    card.append(name, price, range, status);
    card.addEventListener('click', () => selectPair(pair));
    cards.set(pair, { card, price, range, status });
    $('watchlist').append(card);
  }
  function applyView(value) {
    enabled = value !== 'desk';
    document.body.dataset.view = enabled ? 'dashboard' : 'desk';
    $('view-toggle').textContent = enabled ? '取引デスクへ' : 'ダッシュボードへ';
    $('page-title').textContent = enabled ? 'ホームダッシュボード' : '取引デスク';
    $('page-eyebrow').textContent = enabled ? 'AT A GLANCE' : 'YOUR PORTFOLIO';
    try { localStorage.setItem(preference, enabled ? 'dashboard' : 'desk'); } catch { /* optional */ }
  }
  let saved;
  try { saved = localStorage.getItem(preference); } catch { /* optional */ }
  applyView(saved);
  $('view-toggle').addEventListener('click', () => applyView(enabled ? 'desk' : 'dashboard'));

  function tick() {
    const now = new Date();
    $('dashboard-clock').textContent = now.toLocaleTimeString('ja-JP', { hour12: false });
    $('dashboard-date').textContent = now.toLocaleDateString('ja-JP', { month: 'long', day: 'numeric', weekday: 'long' });
    let fresh = 0;
    for (const [pair, elements] of cards) {
      const quote = quotes.get(pair);
      const age = quote ? Math.max(0, Math.floor((Date.now() - quote.at) / 1000)) : null;
      const stale = !quote || quote.failed || age > 90;
      elements.card.classList.toggle('stale', stale);
      elements.status.textContent = quote
        ? `${stale ? '更新待ち · ' : ''}${age < 60 ? `${age}秒前` : `${Math.floor(age / 60)}分前`}に取得`
        : 'データ取得待ち';
      if (!stale) fresh++;
    }
    $('dashboard-health').textContent = !navigator.onLine ? 'オフライン · 再接続を待っています' : fresh === 4 ? '相場を自動更新中 · 30秒間隔' : `相場 ${fresh}/4 通貨を更新 · 未取得・遅延あり`;
    $('dashboard-health').classList.toggle('valuation-warning', fresh < 4 || !navigator.onLine);
  }
  async function refresh() {
    if (loading || document.hidden) return;
    loading = true;
    try {
      for (const pair of pairs) {
        try {
          const data = await api(`/api/ticker?pair=${pair}`);
          if (data.last == null || !Number.isFinite(Number(data.last))) throw new Error('Invalid price');
          quotes.set(pair, { at: Date.now(), failed: false });
          const elements = cards.get(pair);
          elements.price.textContent = `¥ ${yen(data.last)}`;
          elements.range.textContent = `24h 安値 ${data.low == null ? '—' : yen(data.low)} / 高値 ${data.high == null ? '—' : yen(data.high)}`;
        } catch {
          const previous = quotes.get(pair);
          if (previous) previous.failed = true;
        }
        tick();
      }
    } finally { loading = false; }
  }
  function selected(pair) {
    for (const [key, { card }] of cards) card.setAttribute('aria-pressed', String(key === pair));
  }
  async function acquireWakeLock() {
    if (!keepAwake || document.hidden || wakeLock || acquiring) return;
    acquiring = true;
    try {
      const lock = await navigator.wakeLock.request('screen');
      if (!keepAwake) { await lock.release(); return; }
      wakeLock = lock;
      $('awake-toggle').textContent = '画面維持 ON';
      lock.addEventListener('release', () => {
        if (wakeLock === lock) wakeLock = null;
        $('awake-toggle').textContent = keepAwake ? '画面維持 待機中' : '画面を点灯維持';
      });
    } catch { $('awake-toggle').textContent = '画面維持できません'; }
    finally { acquiring = false; }
  }
  $('awake-toggle').disabled = !navigator.wakeLock;
  if (!navigator.wakeLock) $('awake-toggle').textContent = '画面維持は未対応';
  $('awake-toggle').addEventListener('click', async () => {
    keepAwake = !keepAwake;
    $('awake-toggle').setAttribute('aria-pressed', String(keepAwake));
    if (keepAwake) await acquireWakeLock();
    else { if (wakeLock) await wakeLock.release(); $('awake-toggle').textContent = '画面を点灯維持'; }
  });
  $('fullscreen-toggle').disabled = !document.fullscreenEnabled;
  $('fullscreen-toggle').addEventListener('click', async () => {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else await document.documentElement.requestFullscreen();
    } catch { $('dashboard-health').textContent = '全画面表示を開始できませんでした'; }
  });
  document.addEventListener('fullscreenchange', () => {
    $('fullscreen-toggle').textContent = document.fullscreenElement ? '全画面を終了' : '全画面';
  });
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) { refresh(); acquireWakeLock(); }
  });
  window.addEventListener('online', refresh);
  window.addEventListener('offline', tick);
  tick(); setInterval(tick, 1000); setInterval(refresh, 30000);
  return { refresh, selected };
}
