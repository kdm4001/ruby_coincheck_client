import { setupAssetHistory } from './asset-history.js';
import { setupDashboard } from './dashboard.js';
import { OrderBook, parseTrades, mergeTrades } from './market.js';

const $ = id => document.getElementById(id);
const book = new OrderBook();
const typeLabels = { buy: '指値買い', sell: '指値売り', market_buy: '成行買い', market_sell: '成行売り' };
const supportedPairs = ['btc_jpy', 'eth_jpy', 'xrp_jpy', 'sol_jpy'];
let session, pair = 'btc_jpy', generation = 0, socket, retryTimer, retry = 0;
let trades = [], history = [], historyCursor, historyMore = false, historyExpanded = false, events = [];
let busy = false, bookLoading = false, privateLoading = false, marketLoading = false, historyLoading = false;
let privateTimer, publicLive = false;
let volume24h = null;
let settingsSaving = false;
let dashboard, assetHistory;
const THEME_KEY = 'coincheck-local-theme';
const num = (value, digits = 8) => value == null ? '—' : Number(value).toLocaleString('ja-JP', { maximumFractionDigits: digits });
const time = value => value ? new Date(value).toLocaleTimeString('ja-JP', { hour12: false }) : '—';
const dateTime = value => value ? new Date(value).toLocaleString('ja-JP', { hour12: false }) : '—';
const coin = () => pair.split('_')[0].toUpperCase();

function applyTheme(theme) {
  const selected = theme === 'dark' ? 'dark' : 'light';
  document.body.dataset.theme = selected;
  const button = $('theme-toggle');
  if (button) {
    const dark = selected === 'dark';
    button.textContent = dark ? '☀ ライト' : '☾ ダーク';
    button.setAttribute('aria-label', dark ? 'ライトモードに切り替え' : 'ダークモードに切り替え');
  }
}

function setupTheme() {
  let saved = null;
  try { saved = localStorage.getItem(THEME_KEY); } catch (_) { /* optional preference */ }
  applyTheme(saved || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
  $('theme-toggle')?.addEventListener('click', () => {
    const next = document.body.dataset.theme === 'dark' ? 'light' : 'dark';
    applyTheme(next);
    try { localStorage.setItem(THEME_KEY, next); } catch (_) { /* optional preference */ }
  });
}

function setupMobileMenu() {
  const toggle = $('mobile-menu-toggle');
  if (!toggle) return;
  toggle.addEventListener('click', () => {
    const open = document.querySelector('.topbar').classList.toggle('menu-open');
    toggle.setAttribute('aria-expanded', String(open));
  });
  document.addEventListener('click', event => {
    const topbar = document.querySelector('.topbar');
    if (topbar.classList.contains('menu-open') && !topbar.contains(event.target)) {
      topbar.classList.remove('menu-open');
      toggle.setAttribute('aria-expanded', 'false');
    }
  });
}

function notice(message, error = false) { $('notice').textContent = message; $('notice').classList.toggle('error', error); }
function requireLogin() {
  session = null;
  clearTimeout(retryTimer);
  clearTimeout(privateTimer);
  if (socket) { socket.onclose = null; socket.close(); }
  $('order-fields').disabled = true;
  location.replace(`/login?pair=${encodeURIComponent(pair)}`);
}
function row(cells, className = '') {
  const tr = document.createElement('tr');
  tr.className = className;
  for (const value of cells) {
    const td = document.createElement('td');
    if (value instanceof Node) td.append(value); else td.textContent = value ?? '—';
    tr.append(td);
  }
  return tr;
}
function empty(target, columns, message) {
  const tr = row([message]); tr.firstChild.colSpan = columns; tr.firstChild.className = 'empty';
  $(target).replaceChildren(tr);
}
async function api(path, body) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetch(path, {
      method: body ? 'POST' : 'GET', signal: controller.signal,
      headers: { 'X-Local-Token': session.token, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {})
    });
    const data = await response.json();
    if (response.status === 401 && data.code === 'login_required') requireLogin();
    if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
    return data;
  } catch (error) {
    if (error.name === 'AbortError' || error instanceof TypeError) {
      throw new Error(body && path.startsWith('/api/orders') ? '通信が途切れ、結果を確認できません。再送信せず注文・約定履歴を確認してください。' : '通信に失敗しました。ページを再読み込みして接続・登録状態を確認してください。');
    }
    throw error;
  } finally { clearTimeout(timeout); }
}
const endpoint = name => `/api/${name}?pair=${encodeURIComponent(pair)}`;

function renderBook() {
  for (const side of ['asks', 'bids']) {
    const rows = book.rows(side);
    if (!rows.length) empty(side, 2, 'データ待ち');
    else $(side).replaceChildren(...rows.map(([price, amount]) => row([num(price), num(amount)], side === 'asks' ? 'sell-text' : 'buy-text')));
  }
}
function renderTrades() {
  $('trades').replaceChildren(...trades.slice(0, 30).map(item => row([time(item.created_at), num(item.rate), num(item.amount)], item.order_type === 'buy' ? 'buy-text' : 'sell-text')));
  if (!trades.length) empty('trades', 3, '約定データ待ち');
  const points = trades.slice().reverse();
  $('chart-empty').hidden = points.length > 1;
  if (points.length < 2) { $('chart-line').setAttribute('d', ''); $('chart-area').setAttribute('d', ''); return; }
  const prices = points.map(item => Number(item.rate));
  const low = Math.min(...prices), high = Math.max(...prices), spread = high - low || Math.max(low * 0.0001, 1);
  const coordinates = prices.map((value, index) => `${index * 800 / (prices.length - 1)},${160 - (value - low) / spread * 140}`);
  const path = `M${coordinates.join(' L')}`;
  $('chart-line').setAttribute('d', path);
  $('chart-area').setAttribute('d', `${path} L800,180 L0,180 Z`);
  $('chart-start').textContent = time(points[0].created_at);
  $('chart-end').textContent = time(points.at(-1).created_at);
}
function updatePrice(price, at) {
  $('last-price').textContent = num(price);
  $('price-time').textContent = `${time(at)} 更新 · JPY`;
  const yenVolume = volume24h != null && price != null ? Number(volume24h) * Number(price) : NaN;
  $('volume-jpy').textContent = Number.isFinite(yenVolume) && yenVolume >= 0
    ? `日本円換算（概算）: 約 ${num(yenVolume, 0)} 円`
    : '日本円換算（概算）: —';
}
async function refreshBook() {
  if (bookLoading) return;
  bookLoading = true;
  const current = generation;
  book.ready = false; book.pending = [];
  $('book-status').textContent = '再取得中';
  try {
    const data = await api(endpoint('book'));
    if (current !== generation) return;
    book.snapshot(data); renderBook();
    $('book-status').textContent = `${time(Date.now())} · ${publicLive ? '参考値' : 'REST のみ'}`;
  } catch (error) {
    if (current === generation) { $('book-status').textContent = '取得失敗・更新待ち'; notice(error.message, true); }
  } finally { if (current === generation) bookLoading = false; }
}
async function refreshMarket() {
  if (marketLoading) return;
  marketLoading = true;
  const current = generation;
  await Promise.allSettled([
    (async () => {
      try {
        const data = await api(endpoint('ticker'));
        if (current !== generation) return;
        volume24h = data.volume;
        updatePrice(data.last, Number(data.timestamp) * 1000 || Date.now());
        $('high-price').textContent = num(data.high); $('low-price').textContent = num(data.low); $('volume').textContent = num(data.volume);
      } catch (error) { if (current === generation) notice(error.message, true); }
    })(),
    (async () => {
      try {
        const data = await api(endpoint('trades'));
        if (current !== generation) return;
        trades = mergeTrades(trades, data.data || []); renderTrades();
      } catch (error) { if (current === generation) notice(error.message, true); }
    })()
  ]);
  if (current === generation) marketLoading = false;
}

function renderBalance(data) {
  $('total-assets').textContent = data.total_jpy == null ? '—' : `¥ ${num(data.total_jpy, 0)}`;
  $('valuation-status').textContent = data.missing_rates.length
    ? `${data.missing_rates.map(currency => currency.toUpperCase()).join('・')} は未評価。評価できた資産: 約 ${num(data.valued_jpy, 0)} 円`
    : `${time(data.updated_at)} 時点 · 基準レートは最大 20 秒キャッシュ · 30 秒ごとに更新`;
  $('valuation-status').classList.toggle('valuation-warning', data.missing_rates.length > 0);
  $('balances').replaceChildren(...data.assets.map(asset => {
    const quantity = document.createElement('div'); quantity.textContent = num(asset.quantity);
    const details = [];
    if (Number(asset.other)) details.push(`貸出・つみたて ${num(asset.other)}`);
    if (Number(asset.debt)) details.push(`借入 ${num(asset.debt)}`);
    if (details.length) { const small = document.createElement('small'); small.className = 'balance-details'; small.textContent = details.join(' / '); quantity.append(small); }
    const value = document.createElement('span');
    value.textContent = asset.value_jpy == null ? '未評価' : `¥ ${num(asset.value_jpy, 0)}`;
    if (asset.rate != null) value.title = `換算レート: 1 ${asset.currency.toUpperCase()} = ${num(asset.rate)} JPY`;
    return row([asset.currency.toUpperCase(), quantity, num(asset.available), num(asset.reserved), value]);
  }));
  if (!data.assets.length) empty('balances', 5, '残高がありません');
  $('balance-status').textContent = `${time(data.updated_at)} 更新`;
}
function renderOrders(data) {
  const orders = data.orders || [];
  $('order-count').textContent = orders.length;
  $('orders').replaceChildren(...orders.map(item => {
    const button = document.createElement('button'); button.textContent = 'キャンセル'; button.className = 'quiet'; button.disabled = busy;
    button.addEventListener('click', () => cancelOrder(item));
    return row([item.id, item.pair.toUpperCase().replace('_', ' / '), typeLabels[item.order_type] || item.order_type, num(item.rate), num(item.pending_amount ?? item.amount), button]);
  }));
  if (!orders.length) empty('orders', 6, 'この通貨ペアに未約定注文はありません');
  $('orders-status').textContent = `${time(Date.now())} 更新`;
}
function renderHistory() {
  $('history').replaceChildren(...history.map(item => row([
    dateTime(item.created_at), item.pair?.toUpperCase().replace('_', ' / '), item.side || item.order_type,
    num(item.rate), Object.entries(item.funds || {}).map(([key, value]) => `${num(value)} ${key.toUpperCase()}`).join(' / ')
  ])));
  if (!history.length) empty('history', 5, '約定履歴はありません');
  $('more-history').hidden = !historyMore;
}
async function loadHistory(more = false) {
  if (historyLoading) return;
  historyLoading = true; $('more-history').disabled = true;
  try {
    const data = await api(`/api/transactions${more && historyCursor ? `?starting_after=${encodeURIComponent(historyCursor)}` : ''}`);
    const items = data.data || data.transactions || [];
    if (more) historyExpanded = true;
    history = more || historyExpanded ? mergeTrades(history, items, 1000) : items;
    if (more || !historyExpanded) {
      historyCursor = items.at(-1)?.id; historyMore = items.length === 25;
    }
    renderHistory(); $('history-status').textContent = `${time(Date.now())} 更新 · 全通貨`;
  } catch (error) { $('history-status').textContent = '取得失敗'; notice(error.message, true); }
  finally { historyLoading = false; $('more-history').disabled = false; }
}
async function refreshPrivate() {
  if (!session?.authenticated || privateLoading) return;
  privateLoading = true;
  const current = generation;
  await Promise.allSettled([
    (async () => { try { renderBalance(await api('/api/portfolio')); } catch (error) { $('balance-status').textContent = '取得失敗 · 表示は前回取得分'; $('valuation-status').textContent = '更新できませんでした。表示額は最新ではありません。'; $('valuation-status').classList.add('valuation-warning'); notice(error.message, true); } })(),
    (async () => { try { const data = await api(endpoint('orders')); if (current === generation) renderOrders(data); } catch (error) { if (current === generation) { $('orders-status').textContent = '取得失敗'; notice(error.message, true); } } })(),
    loadHistory()
  ]);
  privateLoading = false;
  assetHistory?.refresh();
  if (current !== generation) refreshPrivate();
}
function schedulePrivateRefresh() {
  clearTimeout(privateTimer);
  privateTimer = setTimeout(() => refreshPrivate(), 700);
}
function streamStatus(source, data) {
  const target = $(source === 'public' ? 'public-status' : 'private-status');
  const names = { connecting: '接続中', connected: '接続済み', reconnecting: '再接続中', error: 'エラー' };
  target.className = `badge ${data.state}`;
  target.textContent = `${source === 'public' ? '相場' : 'アカウント'} · ${names[data.state] || data.state}`;
  if (source === 'public') {
    publicLive = data.state === 'connected';
    if (publicLive) { refreshBook(); refreshMarket(); }
    else { $('book-status').textContent = '配信停止 · 再取得待ち'; book.reset(); renderBook(); }
  } else if (data.state === 'connected') schedulePrivateRefresh();
  if (data.message) notice(data.message, true);
}
function streamMessage(source, data) {
  if (source === 'private') {
    if (!data.channel) return;
    events.unshift(`${time(Date.now())}  ${data.channel} · ${data.pair || ''} · 注文 ${data.order_id || data.id || ''} ${data.order_event || data.side || ''}`);
    events = events.slice(0, 50);
    $('events').replaceChildren(...events.map(text => { const li = document.createElement('li'); li.textContent = text; return li; }));
    schedulePrivateRefresh(); return;
  }
  if (Array.isArray(data) && data[0] === pair && data[1]?.bids && data[1]?.asks) {
    book.delta(data[1]); if (book.ready) { renderBook(); $('book-status').textContent = `${time(Date.now())} · 参考値`; }
  } else {
    const incoming = parseTrades(data, pair);
    if (!incoming.length) return;
    trades = mergeTrades(trades, incoming); renderTrades(); updatePrice(trades[0].rate, trades[0].created_at);
  }
}
function connect() {
  clearTimeout(retryTimer);
  if (socket) { socket.onclose = null; socket.close(); }
  const current = generation;
  socket = new WebSocket(`ws://${location.host}/stream?pair=${encodeURIComponent(pair)}`, ['coincheck-local', session.token]);
  socket.onopen = () => { retry = 0; notice('相場に接続しました。自動更新しています。'); };
  socket.onmessage = event => {
    if (current !== generation) return;
    try {
      const message = JSON.parse(event.data);
      if (message.type === 'login_required') { requireLogin(); return; }
      if (message.type === 'session_changed') {
        if (!settingsSaving) location.reload();
        return;
      }
      if (message.type === 'status') streamStatus(message.source, message.data);
      else if (message.type === 'message') streamMessage(message.source, message.data);
    } catch { notice('配信データを読み取れませんでした。更新をお試しください。', true); }
  };
  socket.onerror = () => notice('リアルタイム接続を確認しています…', true);
  socket.onclose = () => {
    if (current !== generation) return;
    streamStatus('public', { state: 'reconnecting' });
    if (session.authenticated) streamStatus('private', { state: 'reconnecting' });
    if (!settingsSaving) retryTimer = setTimeout(connect, Math.min(1000 * 2 ** retry++, 30000));
  };
}

function updateForm() {
  const type = $('order-type').value, limit = ['buy', 'sell'].includes(type), marketBuy = type === 'market_buy';
  $('rate-field').hidden = !limit; $('rate').disabled = !limit; $('rate').required = limit;
  $('amount-field').hidden = marketBuy; $('amount').disabled = marketBuy; $('amount').required = !marketBuy;
  $('market-amount-field').hidden = !marketBuy; $('market-amount').disabled = !marketBuy; $('market-amount').required = marketBuy;
  $('post-only-label').hidden = !limit; $('post-only').disabled = !limit;
  const estimate = marketBuy ? Number($('market-amount').value) : limit ? Number($('rate').value) * Number($('amount').value) : 0;
  $('estimate').textContent = estimate > 0 ? `≈ ${num(estimate, 2)} JPY` : '—';
}
function setBusy(value) {
  busy = value; $('order-fields').disabled = value || !session?.authenticated;
  $('open-settings').disabled = value;
  $('logout').disabled = value;
  $('pair').disabled = value;
  $('orders').querySelectorAll('button').forEach(button => { button.disabled = value; });
}
function confirm(title, description) {
  $('confirm-title').textContent = title; $('confirm-body').textContent = description;
  const dialog = $('confirm-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
  return new Promise(resolve => dialog.addEventListener('close', () => resolve(dialog.returnValue === 'confirm'), { once: true }));
}
async function submitOrder(event) {
  event.preventDefault(); if (busy) return;
  const data = { pair, order_type: $('order-type').value };
  for (const [key, value] of new FormData($('order-form'))) if (value && key !== 'order_type') data[key] = value.trim();
  if (!$('post-only').disabled && $('post-only').checked) data.time_in_force = 'post_only';
  const description = [`通貨ペア: ${pair.toUpperCase()}`, `注文方法: ${typeLabels[data.order_type]}`, data.rate && `価格: ${data.rate} JPY`, data.amount && `数量: ${data.amount} ${coin()}`, data.market_buy_amount && `購入金額: ${data.market_buy_amount} JPY`, data.stop_loss_rate && `逆指値: ${data.stop_loss_rate} JPY`, data.time_in_force && 'Post only: 有効'].filter(Boolean).join('\n');
  setBusy(true);
  try {
    if (!await confirm('注文内容の確認', description)) return;
    const response = await api('/api/orders', { ...data, request_id: crypto.randomUUID() });
    notice(`注文を受け付けました。注文 ID: ${response.id ?? '取得待ち'}`);
  } catch (error) { notice(error.message, true); }
  finally { setBusy(false); await refreshPrivate(); }
}
async function cancelOrder(order) {
  if (busy) return;
  setBusy(true);
  try {
    if (!await confirm('注文をキャンセル', `注文 ID: ${order.id}\n通貨ペア: ${order.pair}\nこの注文をキャンセルします。`)) return;
    await api(`/api/orders/${encodeURIComponent(order.id)}/cancel`, { request_id: crypto.randomUUID() });
    notice(`注文 ${order.id} のキャンセルを送信しました。注文一覧で結果を確認してください。`);
  } catch (error) { notice(error.message, true); }
  finally { setBusy(false); await refreshPrivate(); }
}
function changePair() {
  const next = $('pair').value.trim().toLowerCase();
  if (!supportedPairs.includes(next)) return;
  if (next === pair) return;
  pair = next; dashboard?.selected(pair); generation++; marketLoading = false; bookLoading = false;
  const url = new URL(location.href); url.searchParams.set('pair', pair);
  window.history.replaceState(null, '', url);
  publicLive = false;
  volume24h = null;
  $('volume-jpy').textContent = '日本円換算（概算）: —';
  trades = []; book.reset(); renderBook(); renderTrades();
  $('market-name').textContent = `${coin()} / JPY`; $('volume-unit').textContent = coin(); $('amount-label').textContent = `数量 (${coin()})`;
  for (const id of ['last-price', 'high-price', 'low-price', 'volume']) $(id).textContent = '—';
  for (const id of ['rate', 'amount', 'market-amount', 'stop-loss']) $(id).value = '';
  $('price-time').textContent = '価格を取得中'; $('orders-status').textContent = '取得中';
  $('order-count').textContent = '0'; empty('orders', 6, '取得中'); updateForm();
  connect(); refreshMarket(); refreshBook(); refreshPrivate();
}

function openSettings() {
  $('credentials-form').reset();
  $('credentials-result').textContent = '';
  $('credentials-state').textContent = session.authenticated ? '登録済み · 別のキーに変更できます' : '未登録';
  $('clear-credentials').hidden = !session.authenticated;
  $('settings-dialog').showModal();
}
async function saveCredentials(event) {
  event.preventDefault();
  if (settingsSaving || busy) return;
  const credentials = { api_key: $('api-key').value.trim(), api_secret: $('api-secret').value.trim() };
  $('credentials-form').reset();
  settingsSaving = true; $('credentials-fields').disabled = true;
  $('credentials-result').textContent = 'Coincheck への接続を確認しています…';
  try {
    session = await api('/api/credentials', credentials);
    $('credentials-result').textContent = '登録しました。画面を更新しています…';
    location.reload();
  } catch (error) { $('credentials-result').textContent = error.message; }
  finally {
    delete credentials.api_key; delete credentials.api_secret;
    settingsSaving = false; $('credentials-fields').disabled = false;
  }
}
async function clearCredentials() {
  if (settingsSaving || busy) return;
  settingsSaving = true; $('credentials-fields').disabled = true;
  $('credentials-form').reset();
  try {
    session = await api('/api/credentials/clear', {});
    location.reload();
  } catch (error) { $('credentials-result').textContent = error.message; }
  finally { settingsSaving = false; $('credentials-fields').disabled = false; }
}
async function start() {
  try {
    setupTheme();
    setupMobileMenu();
    const response = await fetch('/api/session');
    if (response.status === 401) { requireLogin(); return; }
    if (!response.ok) throw new Error('ローカルサーバーに接続できません');
    session = await response.json();
    $('setup').hidden = session.authenticated; $('order-fields').disabled = !session.authenticated;
    $('order-help').textContent = session.authenticated ? '確定操作を行うと実際に発注されます。' : 'API キーを設定すると取引できます。';
    if (!session.authenticated) $('private-status').textContent = 'アカウント · API キー未設定';
    $('pair').addEventListener('change', changePair);
    $('open-settings').addEventListener('click', openSettings);
    $('logout').addEventListener('click', async () => {
      if (busy) return;
      setBusy(true);
      try { await api('/api/logout', {}); requireLogin(); }
      catch (error) { notice(error.message, true); if (session) setBusy(false); }
    });
    $('close-settings').addEventListener('click', () => $('settings-dialog').close());
    $('settings-dialog').addEventListener('cancel', event => { if (settingsSaving) event.preventDefault(); });
    $('settings-dialog').addEventListener('close', () => $('credentials-form').reset());
    $('credentials-form').addEventListener('submit', saveCredentials);
    $('clear-credentials').addEventListener('click', clearCredentials);
    $('refresh').addEventListener('click', () => { refreshMarket(); refreshBook(); refreshPrivate(); dashboard.refresh(); });
    $('more-history').addEventListener('click', () => loadHistory(true));
    $('order-form').addEventListener('submit', submitOrder);
    $('order-form').addEventListener('input', updateForm);
    assetHistory = setupAssetHistory({ api, authenticated: session.authenticated });
    dashboard = setupDashboard({ api, selectPair: next => {
      if (busy) return;
      $('pair').value = next; changePair();
    } });
    dashboard.selected(pair); dashboard.refresh();
    const requestedPair = new URL(location.href).searchParams.get('pair');
    $('pair').value = supportedPairs.includes(requestedPair) ? requestedPair : pair;
    updateForm(); renderBook(); renderTrades();
    if ($('pair').value !== pair) changePair();
    else { refreshPrivate(); connect(); refreshMarket(); refreshBook(); }
    setInterval(() => { if (!document.hidden) refreshMarket(); }, 15000);
    setInterval(() => { if (!document.hidden) { refreshBook(); refreshPrivate(); } }, 30000);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) { refreshMarket(); refreshBook(); refreshPrivate(); } });
  } catch (error) { notice(error.message, true); }
}
start();
