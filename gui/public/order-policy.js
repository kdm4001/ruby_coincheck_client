export const policyLabels = { normal: '通常', immediate_or_cancel: '擬似IOC', good_til_date: 'GTD' };

export function prepareOrder(data, policy, expiry, now = Date.now()) {
  if (!Object.hasOwn(policyLabels, policy)) throw new Error('有効期間を確認してください。');
  const body = { ...data };
  if (policy === 'normal') return { path: '/api/orders', body };
  if (!['buy', 'sell'].includes(body.order_type)) throw new Error('IOC・GTDは指値注文だけで利用できます。');
  delete body.stop_loss_rate;
  delete body.time_in_force;
  if (policy === 'good_til_date') {
    const deadline = new Date(expiry).getTime();
    if (!Number.isFinite(deadline) || deadline <= now || deadline > now + 7 * 86400000) {
      throw new Error('取消期限は現在より未来、7日以内で指定してください。');
    }
    body.expires_at = new Date(deadline).toISOString();
  }
  return { path: `/api/orders/${policy}`, body };
}

export function resultText(result) {
  const labels = { filled: '全量約定', canceled: '取消済み', expired: '失効', rejected: '発注拒否', open: '未約定分あり', unknown: '確認不能・要確認' };
  const amount = value => value == null ? '不明' : value;
  return `${labels[result.status] || '結果未確認'} · 約定 ${amount(result.executed_amount)} / 残り ${amount(result.remaining_amount)} / 取消 ${amount(result.canceled_amount)}`;
}
