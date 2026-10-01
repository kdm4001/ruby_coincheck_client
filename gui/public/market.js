// The public feed has no sequence ID. A REST snapshot plus buffered deltas is
// best effort, with regular re-snapshots; never use this as an execution price.
export class OrderBook {
  constructor() { this.reset(); }
  reset() { this.bids = new Map(); this.asks = new Map(); this.pending = []; this.ready = false; }
  snapshot(data) {
    this.bids.clear(); this.asks.clear();
    this.apply(data);
    this.pending.forEach(delta => this.apply(delta));
    this.pending = []; this.ready = true;
  }
  delta(data) {
    if (this.ready) this.apply(data);
    else {
      this.pending.push(data);
      if (this.pending.length > 5000) this.pending.shift();
    }
  }
  apply(data) {
    for (const side of ['bids', 'asks']) {
      for (const [price, amount] of data[side] || []) {
        const key = Number(price);
        if (!Number.isFinite(key) || !Number.isFinite(Number(amount))) continue;
        if (Number(amount) === 0) this[side].delete(key);
        else this[side].set(key, amount);
      }
    }
  }
  rows(side, limit = 10) {
    return [...this[side]].sort((a, b) => side === 'bids' ? b[0] - a[0] : a[0] - b[0]).slice(0, limit);
  }
}

export function parseTrades(payload, pair) {
  if (!Array.isArray(payload) || !Array.isArray(payload[0])) return [];
  return payload.filter(row => row[2] === pair && row.length >= 6).map(row => ({
    id: String(row[1]), pair: row[2], rate: row[3], amount: row[4], order_type: row[5],
    created_at: new Date(Number(row[0]) * 1000).toISOString()
  }));
}

export function mergeTrades(existing, incoming, limit = 100) {
  const items = new Map(existing.map(item => [String(item.id), item]));
  incoming.forEach(item => items.set(String(item.id), item));
  return [...items.values()].sort((a, b) => new Date(b.created_at) - new Date(a.created_at) || Number(b.id) - Number(a.id)).slice(0, limit);
}
