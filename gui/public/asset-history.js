const $ = id => document.getElementById(id);
const yen = value => Number(value).toLocaleString('ja-JP', { maximumFractionDigits: 0 });
const date = at => new Date(at * 1000).toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });

export function historyGeometry(points) {
  if (!points.length) return null;
  const values = points.map(point => Number(point.total_jpy));
  const low = Math.min(...values), high = Math.max(...values);
  const start = points[0].at, end = points.at(-1).at;
  const spread = high - low || Math.max(Math.abs(low) * 0.01, 1);
  const coordinates = points.map((point, index) => [
    end === start ? 400 : 8 + (point.at - start) / (end - start) * 784,
    high === low ? 80 : 148 - (values[index] - low) / spread * 136
  ]);
  const path = coordinates.map(([x, y], index) => `${index === 0 || points[index].at - points[index - 1].at > 900 ? 'M' : 'L'}${x.toFixed(2)},${y.toFixed(2)}`).join(' ');
  return { low, high, start, end, path, last: coordinates.at(-1), change: values.at(-1) - values[0] };
}

export function setupAssetHistory({ api, authenticated }) {
  let generation = 0;
  async function refresh() {
    if (!authenticated) return;
    const current = ++generation;
    try {
      const data = await api(`/api/portfolio/history?days=${$('asset-period').value}`);
      if (current !== generation) return;
      const geometry = historyGeometry(data.points);
      $('asset-chart-empty').hidden = !!geometry;
      $('asset-chart-dot').toggleAttribute('hidden', !geometry);
      $('asset-chart-line').setAttribute('d', geometry?.path || '');
      $('asset-history-status').classList.toggle('valuation-warning', !!data.error);
      $('asset-history-status').textContent = data.error || (geometry
        ? `最終記録 ${date(geometry.end)} · 5分間隔 · 過去30日分をこのPCに保存`
        : '最初の記録を待っています · 完全に評価できた総資産だけを保存します');
      if (!geometry) {
        $('asset-chart-empty').textContent = 'まだ記録がありません';
        $('asset-change').textContent = '記録がたまると変化を表示します';
        for (const id of ['asset-chart-start', 'asset-chart-end', 'asset-chart-high', 'asset-chart-low']) $(id).textContent = '—';
        return;
      }
      $('asset-chart-dot').setAttribute('cx', geometry.last[0]);
      $('asset-chart-dot').setAttribute('cy', geometry.last[1]);
      $('asset-chart-high').textContent = `¥ ${yen(geometry.high)}`;
      $('asset-chart-low').textContent = `¥ ${yen(geometry.low)}`;
      $('asset-chart-start').textContent = date(geometry.start);
      $('asset-chart-end').textContent = date(geometry.end);
      $('asset-change').textContent = data.points.length < 2 ? '最初の記録を保存しました · 次の記録は約5分後' : `期間内の評価額変化 ${geometry.change > 0 ? '+' : ''}${yen(geometry.change)} 円`;
    } catch {
      if (current !== generation) return;
      $('asset-history-status').textContent = '履歴を取得できません · 表示は前回取得分';
      $('asset-history-status').classList.add('valuation-warning');
    }
  }
  $('asset-period').addEventListener('change', refresh);
  refresh();
  return { refresh };
}
